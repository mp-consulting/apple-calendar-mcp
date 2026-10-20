import CalendarStore
import Foundation
import MCP

/// What a tool touches, for listing, policy checks and the activity log.
public enum ToolKind: String, Sendable {
    /// Reads calendars only.
    case read
    /// Writes a file the user asked for (exports), or opens Calendar.
    case fileWrite
    /// Creates, changes or deletes events.
    case change
}

public struct ToolReply: Sendable {
    public var json: JSON
    public var summary: String
    /// The event this call was about: the activity log links to it.
    public var event: Event? = nil
}

public struct ToolDefinition: Sendable {
    public var tool: Tool
    public var kind: ToolKind
    public var run: @Sendable (Arguments) async throws -> ToolReply
}

/// Asks the user in the menu bar app and returns their answer; throws when the app cannot be reached.
public typealias Approver = @Sendable (ApprovalRequest, TimeInterval) throws -> ApprovalDecision

/// All MCP tools, bound to a calendar backend and the user's settings.
public final class CalendarToolbox: @unchecked Sendable {
    /// The backend, made on first use, so the server always starts and every tool can explain what is missing.
    public var backend: any CalendarBackend {
        get throws {
            try lock.withLock {
                if let made = _backend { return made }
                let made = try backendProvider()
                _backend = made
                return made
            }
        }
    }
    private let backendProvider: @Sendable () throws -> any CalendarBackend
    private var _backend: (any CalendarBackend)?
    public let settings: SettingsProvider
    public let activity: ActivityLog?
    /// Recent changes, for `undo_change`; nil turns undo off.
    public let journal: ChangeJournal?
    public let approver: Approver
    /// Started with --read-only: changing tools are not even listed.
    public let readOnly: Bool
    /// The time tools treat as now (tests fix it).
    public var now: @Sendable () -> Date = { Date() }
    /// Opens a URL (Calendar links); tests record instead.
    public var open: @Sendable (URL) -> Bool = { _ in false }
    public var clientName: String? {
        get { lock.withLock { _clientName } }
        set { lock.withLock { _clientName = newValue } }
    }

    private let lock = NSLock()
    private var _listed: (all: [ToolDefinition], byName: [String: ToolDefinition])?
    private var _clientName: String?

    public init(
        backend: @escaping @Sendable () throws -> any CalendarBackend, settings: SettingsProvider = SettingsProvider(),
        activity: ActivityLog? = ActivityLog(), journal: ChangeJournal? = ChangeJournal(),
        approver: @escaping Approver = { _, _ in throw ToolError("No approval is possible here.") }, readOnly: Bool = false
    ) {
        backendProvider = backend
        self.settings = settings
        self.activity = activity
        self.journal = journal
        self.approver = approver
        self.readOnly = readOnly
    }

    public static let instructions = """
        Apple Calendar on this Mac, every account Calendar has (iCloud, Google, Exchange, CalDAV, subscriptions), \
        through EventKit. Start with agenda for a day, list_events for a period, search_events to find events, \
        find_free_time before proposing times. Times without an offset are the user's local time. Event ids are \
        strings; one occurrence of a repeating event is "<id>#<unix seconds>", as the tools return it. \
        create_event and update_event change the calendar right away (use dry_run to preview); deleting, and \
        changing events other people are invited to, may wait for the user's OK in the menu bar app. \
        EventKit cannot invite people or answer invitations: say so and offer open_in_calendar.
        """

    // MARK: Calendars

    /// Calendars Claude may see: all but the hidden ones.
    func visibleCalendars() throws -> [CalendarInfo] {
        let hidden = Set(settings.current.hiddenCalendars)
        return try backend.calendars().filter { !hidden.contains($0.id) }
    }

    /// The calendars named in `key` (ids, titles, or "Account/Title"), else nil for "all visible".
    func calendarIDs(_ arguments: Arguments, key: String = "calendars") throws -> [String]? {
        let names = try arguments.strings(key)
        let visible = try visibleCalendars()
        guard !names.isEmpty else {
            return settings.current.hiddenCalendars.isEmpty ? nil : visible.map(\.id)
        }
        return try names.map { try resolveCalendar($0, in: visible).id }
    }

    /// One calendar by id, title, or "Account/Title" (titles repeat across accounts).
    func resolveCalendar(_ name: String, in visible: [CalendarInfo]? = nil) throws -> CalendarInfo {
        let calendars = try visible ?? visibleCalendars()
        if let exact = calendars.first(where: { $0.id == name }) { return exact }
        let matches = calendars.filter {
            $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || "\($0.account)/\($0.title)".compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        let list = calendars.map { "\($0.account)/\($0.title)" }.joined(separator: ", ")
        if matches.isEmpty { throw ToolError("No calendar \"\(name)\". Calendars: \(list).") }
        throw ToolError("Several calendars are called \"\(name)\": \(matches.map { "\($0.account)/\($0.title)" }.joined(separator: ", ")). Name one as Account/Title.")
    }

    /// Events in a period from the visible calendars.
    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [Event] {
        guard end > start else { throw ToolError("end must be after start") }
        guard end.timeIntervalSince(start) <= 10 * 366 * 86_400 else { throw ToolError("The period is longer than 10 years; narrow it.") }
        let hidden = Set(settings.current.hiddenCalendars)
        return try backend.events(in: start, end, calendarIDs: calendarIDs).filter { !hidden.contains($0.calendarID) }
    }

    /// The event `ref` names, when its calendar is visible.
    func event(_ ref: EventRef) throws -> Event {
        guard let event = try backend.event(ref), !settings.current.hiddenCalendars.contains(event.calendarID) else {
            throw ToolError(CalendarError.notFound(ref).description)
        }
        return event
    }

    // MARK: Policies

    func requireChanges() throws {
        guard settings.current.allowCalendarChanges else {
            throw ToolError("Changing the calendar is turned off (Apple Calendar MCP settings › \"Allow changes\").")
        }
    }

    func checkBatch(_ count: Int) throws {
        let limit = settings.current.maxBatchSize
        guard count <= limit else {
            throw ToolError("Too many events (\(count)); the limit per call is \(limit). Split the work or raise the limit in settings.")
        }
    }

    /// Applies the delete and shared-event policies to `events`; may wait for the user's OK in the menu bar app.
    func authorize(tool: String, deleting: Bool, events: [Event], detail: String? = nil) async throws {
        let current = settings.current
        let shared = events.filter(\.hasOtherAttendees)
        var ask = false
        if deleting {
            switch current.deletePolicy {
            case .never: throw ToolError("Deleting events is turned off (delete policy \"never\"). Nothing was deleted.")
            case .confirm: ask = true
            case .allow: break
            }
        }
        if !shared.isEmpty {
            switch current.sharedEventPolicy {
            case .never:
                throw ToolError("Changing events other people are invited to is turned off. Nothing was changed: \(shared.map(\.title).joined(separator: ", ")).")
            case .confirm: ask = true
            case .allow: break
            }
        }
        guard ask else { return }
        let people = Array(Set(shared.flatMap { $0.attendees.filter { !$0.isCurrentUser && $0.kind == .person }.map(\.formatted) })).sorted()
        let title = events.count == 1 ? events[0].title : "\(events.count) events"
        let request = ApprovalRequest(
            tool: tool, client: clientName, kind: shared.isEmpty ? .delete : .notify, title: title,
            items: events.prefix(30).map(Render.line) + (events.count > 30 ? ["… and \(events.count - 30) more"] : []),
            attendees: Array(people.prefix(40)), detail: detail)
        let timeout = current.approvalTimeout
        let decision: ApprovalDecision
        do {
            decision = try await Task.detached { try self.approver(request, timeout) }.value
        } catch {
            throw ToolError("This needs your OK in the Apple Calendar MCP app, which could not be reached (\(error)). Nothing was changed.")
        }
        switch decision {
        case .approved: return
        case .denied: throw ToolError("The user declined this in Apple Calendar MCP. Nothing was changed.")
        case .timedOut: throw ToolError("No answer in Apple Calendar MCP within \(Int(timeout)) s. Nothing was changed.")
        }
    }

    func record(_ records: [ChangeRecord]) { journal?.append(records) }

    // MARK: Tool list

    public var definitions: [ToolDefinition] { readTools + changeTools + fileTools + undoTools }

    /// Tools offered to clients (no changing tools in read-only launches). Built once.
    public var listedDefinitions: [ToolDefinition] { listed.all }

    private var listed: (all: [ToolDefinition], byName: [String: ToolDefinition]) {
        if let built = lock.withLock({ _listed }) { return built }
        let all = readOnly ? definitions.filter { $0.kind != .change } : definitions
        let built = (all, Dictionary(all.map { ($0.tool.name, $0) }, uniquingKeysWith: { first, _ in first }))
        lock.withLock { _listed = built }
        return built
    }

    /// Runs a tool and logs it (unless `logged` is false: resource refreshes). Errors come back as tool errors, never as
    /// protocol failures.
    public func call(_ name: String, arguments: [String: Value]?, logged: Bool = true) async -> CallTool.Result {
        let started = Date()
        let activity = logged ? self.activity : nil
        guard let definition = listed.byName[name] else {
            return .init(content: [.text(text: "Unknown tool \(name)", annotations: nil, _meta: nil)], isError: true)
        }
        // A line now, so a call that hangs (or a server that dies) still shows up, and with which tool.
        let entryID = UUID()
        let pid = ProcessInfo.processInfo.processIdentifier
        let isWrite = definition.kind == .change
        activity?.append(ActivityEntry(
            id: entryID, date: started, pid: pid, client: clientName, tool: name, ok: true, milliseconds: 0, summary: "running",
            isWrite: isWrite, running: true))
        var ok = true
        var text: String
        var summary: String
        var link: String?
        do {
            var parsed = Arguments(arguments)
            parsed.now = now()
            if let zone = try parsed.string("time_zone") {
                guard let timeZone = TimeZone(identifier: zone) else { throw ToolError("time_zone \"\(zone)\" is not a time zone (use names like Europe/Paris)") }
                parsed.timeZone = timeZone
            }
            let reply = try await definition.run(parsed)
            text = (isWrite ? reply.json.adding("server_version", .string(CalendarMCPVersion.build)) : reply.json).serialized()
            summary = reply.summary
            link = reply.event.map(Render.link)
        } catch {
            ok = false
            text = "Error: \(error)"
            summary = error is CancellationError ? "cancelled by the client" : String(describing: error).components(separatedBy: "\n").first ?? "error"
        }
        activity?.append(ActivityEntry(
            id: entryID, date: started, pid: pid, client: clientName, tool: name, ok: ok,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000), summary: Render.truncate(summary, 160), isWrite: isWrite, link: link))
        return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: ok ? nil : true)
    }

    static func tool(
        _ name: String, _ title: String, _ description: String, _ schema: Value, kind: ToolKind, destructive: Bool = false,
        idempotent: Bool = false
    ) -> Tool {
        Tool(
            name: name, title: title, description: description, inputSchema: schema,
            annotations: .init(
                title: title, readOnlyHint: kind == .read, destructiveHint: kind == .read ? nil : destructive,
                idempotentHint: kind == .read ? nil : idempotent, openWorldHint: false))
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
}
