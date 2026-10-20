import CalendarStore
import Foundation

/// Files shared by the MCP server processes and the menu bar app.
public enum SharedPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["APPLE_CALENDAR_MCP_SUPPORT_DIR"], !override.isEmpty {
            return URL(filePath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/apple-calendar-mcp")
    }

    public static var settings: URL { supportDirectory.appending(path: "settings.json") }
    public static var activityLog: URL { supportDirectory.appending(path: "activity.jsonl") }
    public static var changeJournal: URL { supportDirectory.appending(path: "changes.json") }
    /// The menu bar app's socket (see `BridgeHost`).
    public static var bridgeSocket: URL { supportDirectory.appending(path: "bridge.sock") }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        chmod(url.path, 0o700)
    }
}

/// Whether something is done right away, after the user's OK in the menu bar app, or never.
public enum Policy: String, Codable, Sendable, CaseIterable {
    case allow
    case confirm
    case never
}

/// User settings, stored as JSON and editable from the menu bar app. The server re-reads the file when it changes,
/// so toggles apply immediately.
public struct Settings: Codable, Sendable, Equatable {
    /// Allow creating, changing and deleting events at all.
    public var allowCalendarChanges = true
    /// Deleting events (Calendar has no Trash): ask first by default.
    public var deletePolicy: Policy = .confirm
    /// Changing or deleting events other people are invited to, whose server may tell them: ask first by default.
    public var sharedEventPolicy: Policy = .confirm
    /// Largest number of events one call may create, change or delete.
    public var maxBatchSize = 50
    /// Calendars (by id) the server never reads, lists or changes.
    public var hiddenCalendars: [String] = []
    /// Working hours, for free time and the agenda (`HH:MM`).
    public var workdayStart = "09:00"
    public var workdayEnd = "18:00"
    /// 1 = Sunday … 7 = Saturday.
    public var workdays: [Int] = [2, 3, 4, 5, 6]
    /// When non-empty, exports may only go inside these folders, and imports only come from them.
    public var fileDirectories: [String] = []
    /// Seconds to wait for an approval.
    public var approvalTimeout: Double = 120
    /// Let the menu bar app look for a new release once a day.
    public var checkForUpdates = true
    /// Refresh installed Claude skills when the app ships newer versions of them.
    public var updateInstalledSkills = true
    /// Show the next event's time and title next to the menu bar icon.
    public var showNextEventInMenuBar = false

    public init() {}

    /// What applies when the settings file exists but cannot be read: nothing is changed or deleted until the user
    /// fixes it, rather than falling back to the permissive defaults.
    public static var failClosed: Settings {
        var settings = Settings()
        settings.allowCalendarChanges = false
        settings.deletePolicy = .never
        settings.sharedEventPolicy = .never
        return settings
    }

    public var workHours: WorkHours {
        WorkHours(
            start: WorkHours.minutes(workdayStart) ?? 9 * 60, end: WorkHours.minutes(workdayEnd) ?? 18 * 60,
            weekdays: Set(workdays.filter { (1...7).contains($0) }))
    }

    public init(from decoder: Decoder) throws {
        // Every key is optional so older/newer files keep loading, and a key with the wrong type costs only that key.
        // The safety switches fail closed instead of falling back to their defaults.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        func field<T: Decodable>(_ key: CodingKeys, _ fallback: T, unreadable: T? = nil) -> T {
            guard container.contains(key) else { return fallback }
            do { return try container.decodeIfPresent(T.self, forKey: key) ?? fallback } catch { return unreadable ?? fallback }
        }
        allowCalendarChanges = field(.allowCalendarChanges, defaults.allowCalendarChanges, unreadable: false)
        deletePolicy = field(.deletePolicy, defaults.deletePolicy, unreadable: .never)
        sharedEventPolicy = field(.sharedEventPolicy, defaults.sharedEventPolicy, unreadable: .never)
        maxBatchSize = field(.maxBatchSize, defaults.maxBatchSize)
        hiddenCalendars = field(.hiddenCalendars, [])
        workdayStart = field(.workdayStart, defaults.workdayStart)
        workdayEnd = field(.workdayEnd, defaults.workdayEnd)
        workdays = field(.workdays, defaults.workdays)
        fileDirectories = field(.fileDirectories, [])
        approvalTimeout = field(.approvalTimeout, defaults.approvalTimeout)
        checkForUpdates = field(.checkForUpdates, defaults.checkForUpdates)
        updateInstalledSkills = field(.updateInstalledSkills, defaults.updateInstalledSkills)
        showNextEventInMenuBar = field(.showNextEventInMenuBar, defaults.showNextEventInMenuBar)
    }

    /// The defaults when there is no file; `failClosed` when the file exists but is not valid settings JSON.
    public static func load(from url: URL = SharedPaths.settings) -> Settings {
        read(from: url) ?? failClosed
    }

    /// nil when the file exists but cannot be read or decoded.
    static func read(from url: URL) -> Settings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    public func save(to url: URL = SharedPaths.settings) throws {
        SharedPaths.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Settings file plus command-line overrides, reloaded when the file changes.
public final class SettingsProvider: @unchecked Sendable {
    private let url: URL
    private let overrides: (inout Settings) -> Void
    private let lock = NSLock()
    private var base = Settings()
    private var cached = Settings()
    private var cachedModification: timespec?
    private var loaded = false

    public init(url: URL = SharedPaths.settings, overrides: @escaping @Sendable (inout Settings) -> Void = { _ in }) {
        self.url = url
        self.overrides = overrides
    }

    public var current: Settings {
        lock.lock()
        defer { lock.unlock() }
        // One stat(2) per look; the file is read again only when it changed.
        var info = stat()
        let modified = stat(url.path, &info) == 0 ? info.st_mtimespec : nil
        if !loaded || modified?.tv_sec != cachedModification?.tv_sec || modified?.tv_nsec != cachedModification?.tv_nsec {
            // A file caught mid-write or broken by hand keeps the last good settings; with none yet, fail closed.
            var settings = Settings.read(from: url) ?? (loaded ? base : Settings.failClosed)
            base = settings
            overrides(&settings)
            cached = settings
            cachedModification = modified
            loaded = true
        }
        return cached
    }
}
