import Foundation

/// One tool call, as shown in the menu bar app. Never contains event titles or notes.
public struct ActivityEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID = UUID()
    public var date: Date
    public var pid: Int32
    public var client: String?
    public var tool: String
    public var ok: Bool
    public var milliseconds: Int
    /// Short outcome, e.g. "12 events" or "moved 1 event".
    public var summary: String
    public var isWrite: Bool
    /// Calendar links (`ical://`) that show the event the call was about, when there is one (`Event.calendarLinks`).
    public var links: [String]?
    /// True on the line written when the call starts; the line written when it finishes has the same `id` and
    /// replaces it. A call that hangs (or a server that died) leaves only this one.
    public var running: Bool?
    /// The server's ``CalendarMCPVersion/build`` (absent before 0.6.2), so the log shows which build each client runs.
    public var version: String?

    public init(
        id: UUID = UUID(), date: Date, pid: Int32, client: String?, tool: String, ok: Bool, milliseconds: Int, summary: String,
        isWrite: Bool, links: [String]? = nil, running: Bool? = nil, version: String? = CalendarMCPVersion.build
    ) {
        self.id = id
        self.version = version
        self.running = running
        self.links = links
        self.date = date
        self.pid = pid
        self.client = client
        self.tool = tool
        self.ok = ok
        self.milliseconds = milliseconds
        self.summary = summary
        self.isWrite = isWrite
    }
}

/// Append-only JSON-lines journal shared by all server processes.
public final class ActivityLog: @unchecked Sendable {
    public let url: URL
    /// Appends run here, one at a time.
    private let writes = DispatchQueue(label: "ActivityLog.writes", qos: .utility)
    private let maxBytes: Int

    public init(url: URL = SharedPaths.activityLog, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    private static let encoder = ISOCoding.encoder
    private static let decoder = ISOCoding.decoder

    /// Written in the background, in order, so a tool's reply does not wait for the disk. `recent`, `stamp` and
    /// `flush` see every entry appended before them.
    public func append(_ entry: ActivityEntry) {
        writes.async { self.store(entry) }
    }

    /// Waits for the entries appended so far to reach the file.
    public func flush() {
        writes.sync {}
    }

    private func store(_ entry: ActivityEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        SharedPaths.ensureDirectory(url.deletingLastPathComponent())
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        // O_APPEND writes of one line are atomic across processes.
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    /// Most recent entries first, one per call: a finished call's line hides its `running` line. Reads only the end
    /// of the log, growing the window until it holds enough lines.
    public func recent(limit: Int = 50) -> [ActivityEntry] {
        flush()
        var entries: [ActivityEntry] = []
        var seen: Set<UUID> = []
        // The current file, then the rotated one if more entries are needed. Each call can take two lines.
        for file in [url, url.appendingPathExtension("1")] {
            guard entries.count < limit else { break }
            for line in Self.lastLines(of: file, count: 2 * (limit - entries.count)) {
                guard let entry = try? Self.decoder.decode(ActivityEntry.self, from: line), seen.insert(entry.id).inserted else { continue }
                entries.append(entry)
                if entries.count >= limit { break }
            }
        }
        return entries
    }

    /// Calls started more than `age` ago that never wrote their finished line: still running, or lost with their
    /// server.
    public func stuck(olderThan age: TimeInterval = 120, now: Date = Date(), window: Int = 400) -> [ActivityEntry] {
        recent(limit: window).filter { $0.running == true && now.timeIntervalSince($0.date) > age }
    }

    /// Size and modification date of the log and its rotated copy: when equal, `recent` returns the same entries.
    public struct Stamp: Equatable, Sendable {
        fileprivate var parts: [[Int64]]
    }

    public func stamp() -> Stamp {
        flush()
        return Stamp(parts: [url, url.appendingPathExtension("1")].map { file in
            var info = stat()
            guard stat(file.path, &info) == 0 else { return [] }
            return [Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec), Int64(info.st_ino)]
        })
    }

    /// Up to `count` complete lines from the end of `file`, newest first.
    static func lastLines(of file: URL, count: Int) -> [Data] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }
        var window: UInt64 = 32 * 1024
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(size - start))
            else { return [] }
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            // Mid-file, the first line is cut off.
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            if lines.count >= count || start == 0 { return lines.suffix(count).reversed().map { Data($0) } }
            window *= 4
        }
    }
}

extension ActivityEntry {
    /// The server build each client used last, most recent first (entries before 0.6.2 carry no version).
    public static func serverVersions(in entries: [ActivityEntry]) -> [(client: String, version: String?, date: Date)] {
        Dictionary(grouping: entries.filter { $0.client != nil }, by: { $0.client! })
            .compactMap { client, entries in entries.max { $0.date < $1.date }.map { (client, $0.version, $0.date) } }
            .sorted { $0.date > $1.date }
    }

    /// Clients whose last call in the past `window` ran a server older than `current`: they start another copy than
    /// the installed one (the Claude extension, an old build), or have not restarted since an update.
    public static func clientsOnOlderServer(
        in entries: [ActivityEntry], current: String = CalendarMCPVersion.current, now: Date = Date(), window: TimeInterval = 3600
    ) -> [(client: String, version: String?)] {
        serverVersions(in: entries.filter { now.timeIntervalSince($0.date) < window })
            .filter { CalendarMCPVersion.isOlder($0.version, than: current) }
            .map { ($0.client, $0.version) }
    }
}
