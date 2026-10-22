import CalendarStore
import Foundation

/// JSON with ISO 8601 dates, for the files the server keeps (journal, activity log).
enum ISOCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// One change a tool made, with what `undo_change` needs to put it back.
public struct ChangeRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case created, updated, deleted
    }

    public var id: UUID
    public var date: Date
    public var tool: String
    public var kind: Kind
    public var span: Span
    /// The event as it was before (updated, deleted).
    public var before: Event?
    /// The event as it is after (created, updated).
    public var after: Event?
    /// When it was undone; an undone change is never undone twice.
    public var undone: Date?

    public init(id: UUID = UUID(), date: Date = Date(), tool: String, kind: Kind, span: Span = .thisEvent, before: Event?, after: Event?) {
        self.id = id
        self.date = date
        self.tool = tool
        self.kind = kind
        self.span = span
        self.before = before
        self.after = after
    }

    /// The event the record is about (after the change when there is one).
    public var event: Event? { after ?? before }
}

/// Recent changes, newest last, for `undo_change`. Owner-only: it holds the events' titles and notes, which undo
/// needs to bring a deleted event back. Keeps the last 200 changes of the last 30 days.
public final class ChangeJournal: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let limit: Int
    private let maxAge: TimeInterval

    public init(url: URL = SharedPaths.changeJournal, limit: Int = 200, maxAge: TimeInterval = 30 * 86_400) {
        self.url = url
        self.limit = limit
        self.maxAge = maxAge
    }

    private static let encoder = ISOCoding.encoder
    private static let decoder = ISOCoding.decoder

    public func records() -> [ChangeRecord] {
        lock.withLock { load() }
    }

    public func append(_ records: [ChangeRecord]) {
        guard !records.isEmpty else { return }
        withFileLock { save(load() + records) }
    }

    public func markUndone(_ id: UUID, at date: Date = Date()) {
        withFileLock {
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            all[index].undone = date
            save(all)
        }
    }

    /// Other servers write the same file: each change reads it fresh and writes it back under an exclusive lock.
    private func withFileLock(_ body: () -> Void) {
        lock.withLock {
            SharedPaths.ensureDirectory(url.deletingLastPathComponent())
            let fd = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
            if fd >= 0 { flock(fd, LOCK_EX) }
            defer {
                if fd >= 0 {
                    flock(fd, LOCK_UN)
                    close(fd)
                }
            }
            body()
        }
    }

    private func load() -> [ChangeRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([ChangeRecord].self, from: data)) ?? []
    }

    private func save(_ records: [ChangeRecord]) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let kept = Array(records.filter { $0.date > cutoff }.suffix(limit))
        SharedPaths.ensureDirectory(url.deletingLastPathComponent())
        guard let data = try? Self.encoder.encode(kept) else { return }
        let temporary = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        _ = rename(temporary.path, url.path)
    }
}
