import Foundation

/// Where calendar data comes from and changes go: EventKit in this process (``EventKitBackend``), EventKit in the
/// menu bar app (``BridgeBackend``), or memory (``MemoryBackend``, for tests and screenshots).
public protocol CalendarBackend: Sendable {
    func access() -> AccessState
    func calendars() throws -> [CalendarInfo]
    /// Events overlapping `start..<end`, repeating ones expanded to their occurrences, sorted by start.
    func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [Event]
    func event(_ ref: EventRef) throws -> Event?
    func create(_ draft: EventDraft) throws -> Event
    func update(_ ref: EventRef, _ change: EventChange, span: Span) throws -> Event
    func delete(_ ref: EventRef, span: Span) throws
    /// Whether the user's answer to the invitation `ref` can be set here.
    func invitationCheck(_ ref: EventRef) throws -> InvitationCheck
    /// Answers the invitation `ref` as the user; Calendar sends the answer to the organizer.
    func respond(_ ref: EventRef, _ answer: InvitationAnswer) throws -> Event
    /// Grows whenever the calendar database changes (in this process or elsewhere).
    func changeCount() -> Int

    // Reminders: the same database, with a permission of its own.
    func reminderAccess() -> AccessState
    func reminderLists() throws -> [CalendarInfo]
    /// Reminders matching `query`, sorted by due date.
    func reminders(_ query: ReminderQuery) throws -> [Reminder]
    func reminder(_ id: String) throws -> Reminder?
    func createReminder(_ draft: ReminderDraft) throws -> Reminder
    func updateReminder(_ id: String, _ change: ReminderChange) throws -> Reminder
    func deleteReminder(_ id: String) throws
}

public struct CalendarError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }

    public static func notFound(_ ref: EventRef) -> CalendarError {
        CalendarError("No event with id \(ref.string). It may have been deleted, or its id changed; search for it again.")
    }

    public static func readOnly(_ title: String) -> CalendarError { CalendarError("\"\(title)\" is read-only.") }

    public static func reminderNotFound(_ id: String) -> CalendarError {
        CalendarError("No reminder with id \(id). It may have been deleted; list the reminders again.")
    }

    public static let endBeforeStart = CalendarError("The end is before the start.")
}

extension CalendarBackend {
    /// `events(from:to:)` over any span: EventKit answers at most four years per query.
    public func events(in start: Date, _ end: Date, calendarIDs: [String]? = nil) throws -> [Event] {
        guard end > start else { return [] }
        let chunk: TimeInterval = 3 * 365 * 86_400
        var results: [Event] = []
        var seen = Set<String>()
        var from = start
        while from < end {
            let to = min(end, from.addingTimeInterval(chunk))
            for event in try events(from: from, to: to, calendarIDs: calendarIDs) where seen.insert(event.id).inserted {
                results.append(event)
            }
            from = to
        }
        return results.sorted(by: Event.chronological)
    }
}

extension Event {
    /// Start, then end, then title: a stable order for lists.
    public static func chronological(_ a: Event, _ b: Event) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.end != b.end { return a.end < b.end }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
