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
    /// A changing tool the dispatcher runs only while "Allow changes" is on; false for one that checks it itself.
    public var guardsChanges: Bool
    public var run: @Sendable (Arguments) async throws -> ToolReply

    init(
        _ name: String, _ title: String, _ description: String, _ schema: Value, kind: ToolKind, destructive: Bool = false,
        idempotent: Bool = false, guardsChanges: Bool? = nil, run: @escaping @Sendable (Arguments) async throws -> ToolReply
    ) {
        tool = Tool(
            name: name, title: title, description: description, inputSchema: schema,
            annotations: .init(
                title: title, readOnlyHint: kind == .read, destructiveHint: kind == .read ? nil : destructive,
                idempotentHint: kind == .read ? nil : idempotent, openWorldHint: false))
        self.kind = kind
        self.guardsChanges = guardsChanges ?? (kind == .change)
        self.run = run
    }
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
        respond_to_invitation accepts or declines an invitation, and Calendar sends the answer to the organizer. \
        create_events and update_events change several events at once, with one approval and one undo_id. \
        Reminders (list_reminders, create_reminder, update_reminder) need Reminders access in the app. \
        EventKit cannot invite people: say so and offer open_in_calendar.
        """

    // MARK: Calendars

    /// Calendars Claude may see: all but the hidden ones.
    func visibleCalendars() throws -> [CalendarInfo] {
        settings.current.visible(try backend.calendars())
    }

    /// The calendars named in `key` (ids, titles, or "Account/Title"), else nil for "all visible".
    func calendarIDs(_ arguments: Arguments, key: String = "calendars") throws -> [String]? {
        try containerIDs(arguments, key: key, noun: "calendar", visible: visibleCalendars)
    }

    /// The calendars or reminder lists named in `key`, else nil for "all visible" (`visible` is read only when needed).
    func containerIDs(_ arguments: Arguments, key: String, noun: String, visible: () throws -> [CalendarInfo]) throws -> [String]? {
        let names = try arguments.strings(key)
        if names.isEmpty && settings.current.hiddenCalendars.isEmpty { return nil }
        let shown = try visible()
        guard !names.isEmpty else { return shown.map(\.id) }
        return try names.map { try resolveCalendar($0, in: shown, noun: noun).id }
    }

    /// A calendar or list Claude may change: the one named in `key`, else the default one (`visible` from
    /// `settings.visible`, which marks the ones Claude may only read).
    func target(_ arguments: Arguments, key: String, in visible: [CalendarInfo], noun: String) throws -> CalendarInfo {
        let found: CalendarInfo
        if let name = try arguments.string(key) {
            found = try resolveCalendar(name, in: visible, noun: noun)
        } else {
            guard let preferred = visible.defaultWritable else { throw ToolError("No \(noun) can take anything new; pass \(key).") }
            found = preferred
        }
        guard found.writable else {
            let why = settings.current.isReadOnly(found.id) ? "Claude may only read it (Apple Calendar MCP settings)" : "it is read-only"
            throw ToolError("\"\(found.title)\" (\(found.account)): \(why); pick another \(noun).")
        }
        return found
    }

    /// One calendar by id, title, or "Account/Title" (titles repeat across accounts).
    func resolveCalendar(_ name: String, in visible: [CalendarInfo]? = nil, noun: String = "calendar") throws -> CalendarInfo {
        let calendars = try visible ?? visibleCalendars()
        if let exact = calendars.first(where: { $0.id == name }) { return exact }
        let matches = calendars.filter {
            $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || "\($0.account)/\($0.title)".compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if matches.count == 1 { return matches[0] }
        let list = calendars.map { "\($0.account)/\($0.title)" }.joined(separator: ", ")
        if matches.isEmpty { throw ToolError("No \(noun) \"\(name)\". The \(noun)s: \(list).") }
        throw ToolError("Several \(noun)s are called \"\(name)\": \(matches.map { "\($0.account)/\($0.title)" }.joined(separator: ", ")). Name one as Account/Title.")
    }

    /// Events in a period from the visible calendars.
    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [Event] {
        guard end > start else { throw ToolError("end must be after start") }
        guard end.timeIntervalSince(start) <= 10 * 366 * 86_400 else { throw ToolError("The period is longer than 10 years; narrow it.") }
        return settings.current.visible(try backend.events(in: start, end, calendarIDs: calendarIDs))
    }

    /// The event `ref` names, when its calendar is visible.
    func event(_ ref: EventRef) throws -> Event {
        guard let event = try backend.event(ref), !settings.current.isHidden(event.calendarID) else {
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

    /// Throws unless every item's calendar (or list) is among `visible` and writable there: `settings.visible` marks
    /// the ones Claude may only read. `nothing` ends the message.
    func requireWritable(
        _ items: [(title: String, containerID: String, containerTitle: String)], in visible: [CalendarInfo], nothing: String
    ) throws {
        let current = settings.current
        for item in items where visible.first(where: { $0.id == item.containerID })?.writable != true {
            let why = current.isReadOnly(item.containerID) ? "which Claude may only read (Apple Calendar MCP settings)" : "which is read-only"
            throw ToolError("\"\(item.title)\" is in \(item.containerTitle), \(why). \(nothing)")
        }
    }

    /// For events; pass `calendars` (from `visibleCalendars()`) when the call already has them.
    func requireWritable(_ events: [Event], in calendars: [CalendarInfo]? = nil, nothing: String = "Nothing was changed.") throws {
        try requireWritable(events.map { ($0.title, $0.calendarID, $0.calendarTitle) }, in: calendars ?? visibleCalendars(), nothing: nothing)
    }

    func checkBatch(_ count: Int) throws {
        let limit = settings.current.maxBatchSize
        guard count <= limit else {
            throw ToolError("Too many events (\(count)); the limit per call is \(limit). Split the work or raise the limit in settings.")
        }
    }

    /// Applies the delete and shared-event policies to `events`; may wait for the user's OK in the menu bar app.
    enum Approval: Equatable {
        case allow
        case ask
        case refuse(String)
    }

    /// What the user's policies say about deleting or changing `events`, without asking anyone.
    func approval(deleting: Bool, events: [Event]) -> Approval {
        let current = settings.current
        let shared = events.filter(\.hasOtherAttendees)
        var ask = false
        if deleting {
            switch current.deletePolicy {
            case .never: return .refuse("Deleting is turned off (delete policy \"never\"). Nothing was deleted.")
            case .confirm: ask = true
            case .allow: break
            }
        }
        if !shared.isEmpty {
            switch current.sharedEventPolicy {
            case .never:
                return .refuse("Changing events other people are invited to is turned off. Nothing was changed: \(shared.map(\.title).joined(separator: ", ")).")
            case .confirm: ask = true
            case .allow: break
            }
        }
        return ask ? .ask : .allow
    }

    /// For a dry run: what the real call would do about approval.
    func approvalPairs(deleting: Bool, events: [Event]) -> [(String, JSON?)] {
        switch approval(deleting: deleting, events: events) {
        case .allow: []
        case .ask: [("asks_first", .bool(true))]
        case .refuse(let reason): [("would_refuse", .string(reason))]
        }
    }

    /// Applies the policies to `events`, asking the user in the app when they say so; throws when refused or declined.
    func authorize(tool: String, deleting: Bool, events: [Event], detail: String? = nil) async throws {
        let people = Array(Set(events.filter(\.hasOtherAttendees).flatMap { $0.otherPeople.map(\.formatted) })).sorted()
        try await authorize(
            tool: tool, deleting: deleting, events: events, title: events.count == 1 ? events[0].title : "\(events.count) events",
            items: events.map(\.summaryLine), attendees: people, detail: detail)
    }

    /// The same for reminders, which have no attendees: only the delete policy applies.
    func authorize(tool: String, deleting reminders: [Reminder]) async throws {
        try await authorize(
            tool: tool, deleting: true, events: [], title: reminders.count == 1 ? reminders[0].title : "\(reminders.count) reminders",
            items: reminders.map(\.summaryLine), subject: .reminder)
    }

    private func authorize(
        tool: String, deleting: Bool, events: [Event], title: String, items: [String], attendees: [String] = [], detail: String? = nil,
        subject: ApprovalRequest.Subject? = nil
    ) async throws {
        switch approval(deleting: deleting, events: events) {
        case .allow: return
        case .refuse(let reason): throw ToolError(reason)
        case .ask: break
        }
        try await ask(ApprovalRequest(
            tool: tool, client: clientName, kind: deleting ? .delete : .notify, title: title, items: Self.lines(items),
            attendees: Array(attendees.prefix(40)), detail: detail, subject: subject))
    }

    /// At most `limit` lines, then "… and N more".
    static func lines(_ all: [String], limit: Int = 30) -> [String] {
        Array(all.prefix(limit)) + (all.count > limit ? ["… and \(all.count - limit) more"] : [])
    }

    /// Asks the user in the app; throws unless they approve.
    func ask(_ request: ApprovalRequest) async throws {
        let timeout = settings.current.approvalTimeout
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

    /// What a call that changes several items did: one undo group, and the failures listed rather than thrown.
    struct Applied<T> {
        var done: [T] = []
        var records: [ChangeRecord] = []
        var failures: [JSON] = []
        let group = UUID()
    }

    /// Runs `body` on each item, between checks for cancellation, and journals what changed as one group. A failure
    /// is listed (named by `label`) and the next item goes on.
    func applyEach<Item, T>(
        _ items: [Item], label: (Item) -> [(String, JSON?)], _ body: (Item, UUID) throws -> (T, ChangeRecord)
    ) throws -> Applied<T> {
        var applied = Applied<T>()
        for item in items {
            try Task.checkCancellation()
            do {
                let (done, record) = try body(item, applied.group)
                applied.done.append(done)
                applied.records.append(record)
            } catch {
                applied.failures.append(.obj(label(item) + [("error", .string(String(describing: error)))]))
            }
        }
        record(applied.records)
        return applied
    }

    /// The `failed` and `undo_id` keys of a reply about `applied`.
    func outcome<T>(_ applied: Applied<T>) -> [(String, JSON?)] {
        [("failed", applied.failures.isEmpty ? nil : .array(applied.failures)), ("undo_id", undoID(applied.records, group: applied.group))]
    }

    /// "deleted 3 events, 1 failed".
    static func summary<T>(_ verb: String, _ noun: String, _ applied: Applied<T>) -> String {
        "\(verb) \(plural(applied.done.count, noun))\(applied.failures.isEmpty ? "" : ", \(applied.failures.count) failed")"
    }

    /// The id `undo_change` takes for `record` (nil when undo is off).
    func undoID(_ record: ChangeRecord) -> JSON? { journal == nil ? nil : .string(record.id.uuidString) }

    /// One id for everything a call changed: the record's own when there is one, else the group's.
    func undoID(_ records: [ChangeRecord], group: UUID) -> JSON? {
        guard journal != nil, !records.isEmpty else { return nil }
        return .string(records.count == 1 ? records[0].id.uuidString : group.uuidString)
    }

    func undoIDs(_ records: [ChangeRecord]) -> JSON? {
        records.isEmpty || journal == nil ? nil : .array(records.map { .string($0.id.uuidString) })
    }

    // MARK: Tool list

    public var definitions: [ToolDefinition] { readTools + changeTools + batchTools + reminderTools + fileTools + undoTools }

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
            if let timeZone = try parsed.timeZone("time_zone") { parsed.timeZone = timeZone }
            if definition.guardsChanges { try requireChanges() }
            let reply = try await definition.run(parsed)
            text = (isWrite ? reply.json.adding("server_version", .string(CalendarMCPVersion.build)) : reply.json).serialized()
            summary = reply.summary
            link = reply.event?.calendarLink
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
}
