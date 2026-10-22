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
    /// Answers an invitation to `ref` as the user (Calendar sends the answer to the organizer), or with `dryRun` only
    /// says whether it can.
    func respond(_ ref: EventRef, _ answer: InvitationAnswer) throws -> InvitationResult
    /// Grows whenever the calendar database changes (in this process or elsewhere).
    func changeCount() -> Int
}

public struct CalendarError: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }

    public static func notFound(_ ref: EventRef) -> CalendarError {
        CalendarError("No event with id \(ref.string). It may have been deleted, or its id changed; search for it again.")
    }
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
