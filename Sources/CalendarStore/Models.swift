import Foundation

/// A calendar as EventKit reports it, with the account it belongs to.
public struct CalendarInfo: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case local, calDAV, exchange, subscription, birthday, unknown
    }

    public var id: String
    public var title: String
    /// The account: "iCloud", "Google", "On My Mac", a subscription's name.
    public var account: String
    public var kind: Kind
    /// `#RRGGBB`.
    public var color: String
    /// False for subscriptions, birthdays, holidays and calendars shared read-only.
    public var writable: Bool
    public var isDefault: Bool

    public init(id: String, title: String, account: String, kind: Kind, color: String, writable: Bool, isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.account = account
        self.kind = kind
        self.color = color
        self.writable = writable
        self.isDefault = isDefault
    }
}

/// How an event shows in free/busy.
public enum Availability: String, Codable, Sendable, CaseIterable {
    case busy, free, tentative, unavailable
}

public enum EventStatus: String, Codable, Sendable {
    case none, confirmed, tentative, cancelled
}

/// One person (or room) invited to an event. EventKit reads these; it cannot invite people.
public struct Participant: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case unknown, pending, accepted, declined, tentative, delegated, completed, inProcess
    }

    public enum Role: String, Codable, Sendable {
        case required, optional, chair, nonParticipant, unknown
    }

    public enum Kind: String, Codable, Sendable {
        case person, room, resource, group, unknown
    }

    public var name: String?
    public var email: String?
    public var status: Status
    public var role: Role
    public var kind: Kind
    public var isCurrentUser: Bool

    public init(
        name: String?, email: String?, status: Status = .unknown, role: Role = .required, kind: Kind = .person,
        isCurrentUser: Bool = false
    ) {
        self.name = name
        self.email = email
        self.status = status
        self.role = role
        self.kind = kind
        self.isCurrentUser = isCurrentUser
    }

    /// "Anna Berg <anna@example.com>", the name or the address alone when only one is known.
    public var formatted: String {
        switch (name, email) {
        case let (name?, email?) where name != email: "\(name) <\(email)>"
        case let (_, email?): email
        case let (name?, nil): name
        case (nil, nil): "(unknown)"
        }
    }

    /// The name, else the address: a short label for counts and lists.
    public var displayName: String { name ?? email ?? "?" }
}

/// A reminder before an event (`minutesBefore`), or at a fixed time.
public struct Alarm: Codable, Sendable, Hashable {
    public var minutesBefore: Int?
    public var at: Date?

    public init(minutesBefore: Int) {
        self.minutesBefore = minutesBefore
        at = nil
    }

    public init(at: Date) {
        minutesBefore = nil
        self.at = at
    }
}

/// A repeat rule: the subset of RFC 5545 that EventKit and people use.
public struct Recurrence: Codable, Sendable, Hashable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily, weekly, monthly, yearly
    }

    public var frequency: Frequency
    public var interval: Int
    /// Stops after this many occurrences…
    public var count: Int?
    /// …or after this date (inclusive).
    public var until: Date?
    /// Weekly: the days, 1 = Sunday … 7 = Saturday (Calendar's numbering).
    public var weekdays: [Int]?
    /// Monthly: the days of the month (negative counts from the end).
    public var monthDays: [Int]?

    public init(
        frequency: Frequency, interval: Int = 1, count: Int? = nil, until: Date? = nil, weekdays: [Int]? = nil,
        monthDays: [Int]? = nil
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.count = count
        self.until = until
        self.weekdays = weekdays
        self.monthDays = monthDays
    }

    public static let weekdayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// "every 2 weeks on Mon, Wed until 2026-12-31".
    public var summary: String {
        let unit = switch frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
        var text = interval == 1 ? "every \(unit)" : "every \(interval) \(unit)s"
        if let weekdays, !weekdays.isEmpty {
            text += " on " + weekdays.sorted().compactMap { (1...7).contains($0) ? Self.weekdayNames[$0] : nil }.joined(separator: ", ")
        }
        if let monthDays, !monthDays.isEmpty { text += " on day " + monthDays.map(String.init).joined(separator: ", ") }
        if let count { text += ", \(count) times" }
        if let until { text += " until \(DayFormat.string(until))" }
        return text
    }
}

/// An event, or one occurrence of a repeating event.
public struct Event: Codable, Sendable, Hashable, Identifiable {
    /// EventKit's `eventIdentifier`: the same for every occurrence of a repeating event.
    public var eventID: String
    /// The iCalendar UID, the same on every device (nil for some local events).
    public var externalID: String?
    /// EventKit's `calendarItemIdentifier` (this Mac only), which Calendar's occurrence links name.
    public var itemID: String?
    public var calendarID: String
    public var calendarTitle: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The event's own time zone; nil for floating events (all-day ones).
    public var timeZone: String?
    public var location: String?
    public var notes: String?
    public var url: String?
    public var availability: Availability
    public var status: EventStatus
    public var organizer: Participant?
    public var attendees: [Participant]
    public var alarms: [Alarm]
    public var recurrence: Recurrence?
    /// A repeating event's occurrence changed on its own (moved, retitled).
    public var isDetached: Bool
    /// For an occurrence of a repeating event: its original start, which identifies it.
    public var occurrenceDate: Date?
    public var created: Date?
    public var modified: Date?

    public init(
        eventID: String, externalID: String? = nil, itemID: String? = nil, calendarID: String, calendarTitle: String, title: String, start: Date,
        end: Date, isAllDay: Bool = false, timeZone: String? = nil, location: String? = nil, notes: String? = nil,
        url: String? = nil, availability: Availability = .busy, status: EventStatus = .none, organizer: Participant? = nil,
        attendees: [Participant] = [], alarms: [Alarm] = [], recurrence: Recurrence? = nil, isDetached: Bool = false,
        occurrenceDate: Date? = nil, created: Date? = nil, modified: Date? = nil
    ) {
        self.eventID = eventID
        self.externalID = externalID
        self.itemID = itemID
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
        self.status = status
        self.organizer = organizer
        self.attendees = attendees
        self.alarms = alarms
        self.recurrence = recurrence
        self.isDetached = isDetached
        self.occurrenceDate = occurrenceDate
        self.created = created
        self.modified = modified
    }

    public var id: String { ref.string }

    /// What tools call this event (one occurrence when it repeats).
    public var ref: EventRef { EventRef(eventID: eventID, occurrence: isRecurring ? occurrenceDate ?? start : nil) }

    public var isRecurring: Bool { recurrence != nil || isDetached }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Other people are invited (the user is not alone on it): changing it may notify them.
    public var hasOtherAttendees: Bool { attendees.contains { !$0.isCurrentUser && $0.kind != .room && $0.kind != .resource } }

    /// The user's own answer to an invitation, when someone else organized it.
    public var myStatus: Participant.Status? {
        guard organizer?.isCurrentUser != true else { return nil }
        return attendees.first(where: \.isCurrentUser)?.status
    }

    /// The people invited besides the user (no rooms or resources).
    public var otherPeople: [Participant] { attendees.filter { !$0.isCurrentUser && $0.kind == .person } }

    /// Still on: not cancelled, and not declined by the user.
    public var isAttended: Bool { status != .cancelled && myStatus != .declined }

    /// Counts toward busy time: attended and not shown as free.
    public var blocksTime: Bool { availability != .free && isAttended }

    public func overlaps(_ start: Date, _ end: Date) -> Bool { self.start < end && self.end > start }
}

/// An event's id in tools: `eventID`, plus `#<unix seconds>` naming one occurrence of a repeating event.
public struct EventRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var eventID: String
    public var occurrence: Date?

    public init(eventID: String, occurrence: Date? = nil) {
        self.eventID = eventID
        self.occurrence = occurrence
    }

    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let hash = text.lastIndex(of: "#"), hash > text.startIndex,
            let seconds = Int64(text[text.index(after: hash)...]), text[text.index(after: hash)...].allSatisfy(\.isNumber)
        {
            eventID = String(text[..<hash])
            occurrence = Date(timeIntervalSince1970: TimeInterval(seconds))
        } else {
            eventID = text
            occurrence = nil
        }
    }

    public var string: String {
        guard let occurrence else { return eventID }
        return "\(eventID)#\(Int64(occurrence.timeIntervalSince1970.rounded()))"
    }

    public var description: String { string }
}

/// Fields for a new event.
public struct EventDraft: Codable, Sendable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// nil: the default calendar for new events.
    public var calendarID: String?
    public var timeZone: String?
    public var location: String?
    public var notes: String?
    public var url: String?
    public var availability: Availability?
    public var alarms: [Alarm]
    public var recurrence: Recurrence?

    public init(
        title: String, start: Date, end: Date, isAllDay: Bool = false, calendarID: String? = nil, timeZone: String? = nil,
        location: String? = nil, notes: String? = nil, url: String? = nil, availability: Availability? = nil, alarms: [Alarm] = [],
        recurrence: Recurrence? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.timeZone = timeZone
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
        self.alarms = alarms
        self.recurrence = recurrence
    }

    /// The fields of `event` that can be written back (attendees and organizer cannot).
    public init(copying event: Event) {
        self.init(
            title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay, calendarID: event.calendarID,
            timeZone: event.timeZone, location: event.location, notes: event.notes, url: event.url, availability: event.availability,
            alarms: event.alarms, recurrence: event.recurrence)
    }
}

/// Changes to an event: nil leaves a field alone; an empty string clears a text field.
public struct EventChange: Codable, Sendable, Hashable {
    public var title: String?
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool?
    public var calendarID: String?
    public var timeZone: String?
    public var location: String?
    public var notes: String?
    public var url: String?
    public var availability: Availability?
    public var alarms: [Alarm]?
    public var recurrence: Recurrence?
    public var removeRecurrence: Bool

    public init(
        title: String? = nil, start: Date? = nil, end: Date? = nil, isAllDay: Bool? = nil, calendarID: String? = nil,
        timeZone: String? = nil, location: String? = nil, notes: String? = nil, url: String? = nil,
        availability: Availability? = nil, alarms: [Alarm]? = nil, recurrence: Recurrence? = nil, removeRecurrence: Bool = false
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.timeZone = timeZone
        self.location = location
        self.notes = notes
        self.url = url
        self.availability = availability
        self.alarms = alarms
        self.recurrence = recurrence
        self.removeRecurrence = removeRecurrence
    }

    public var isEmpty: Bool { self == EventChange() }

    /// The change that puts `event`'s writable fields back as they are now.
    public init(restoring event: Event) {
        self.init(
            title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay, calendarID: event.calendarID,
            timeZone: event.timeZone ?? "", location: event.location ?? "", notes: event.notes ?? "", url: event.url ?? "",
            availability: event.availability, alarms: event.alarms, recurrence: event.recurrence,
            removeRecurrence: event.recurrence == nil)
    }

    /// `event` with this change applied, as a backend saves it (an end before the start keeps the duration).
    public func applied(to event: Event) -> Event {
        var copy = event
        if let title { copy.title = title }
        if let isAllDay { copy.isAllDay = isAllDay }
        if let start {
            if end == nil { copy.end = start.addingTimeInterval(event.duration) }
            copy.start = start
        }
        if let end { copy.end = end }
        if let timeZone { copy.timeZone = timeZone.isEmpty ? nil : timeZone }
        if let location { copy.location = location.isEmpty ? nil : location }
        if let notes { copy.notes = notes.isEmpty ? nil : notes }
        if let url { copy.url = url.isEmpty ? nil : url }
        if let availability { copy.availability = availability }
        if let alarms { copy.alarms = alarms }
        if removeRecurrence { copy.recurrence = nil }
        if let recurrence { copy.recurrence = recurrence }
        return copy
    }
}

/// Which occurrences of a repeating event a change or deletion applies to.
public enum Span: String, Codable, Sendable {
    case thisEvent = "this"
    case futureEvents = "future"
}

extension Event {
    /// Calendar's own link to the event, as tools report it. Showing the event takes `calendarLinks`.
    public var calendarLink: String { calendarLinks.last! }

    /// The links that show the event in Calendar, to open in this order and in one request. `ekevent` shows a
    /// repeating event's first occurrence, so an occurrence gets Calendar's occurrence link,
    /// `<original start>/<calendarItemIdentifier>` (the start in UTC, or as written for floating events). Calendar
    /// finds an occurrence only among the days it shows, so a link to its day comes first: local noon, in UTC.
    public var calendarLinks: [String] {
        let pathAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let occurrence = ref.occurrence, let itemID else {
            return ["ical://ekevent/\(eventID.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? eventID)?method=show&options=more"]
        }
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: occurrence) ?? occurrence
        let stamp = ICS.utc(occurrence, in: timeZone == nil ? .current : .gmt)
        return [
            "ical://date/\(ICS.utc(noon, format: "%04d-%02d-%02d_%02d-%02d-%02d"))?method=show",
            "ical://occurrence/\(stamp)/\(itemID.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? itemID)?method=show&options=more",
        ]
    }

    /// "Tue 21 Oct 14:00–15:00 · Design review · Work", for approvals and summaries.
    public var summaryLine: String {
        let when: String
        if isAllDay {
            when = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " (all day)"
        } else {
            let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
            when = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) + "–"
                + (sameDay ? end.formatted(.dateTime.hour().minute()) : end.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        }
        return [when, title, calendarTitle].joined(separator: " · ")
    }
}

extension [CalendarInfo] {
    /// Where new events go: the default calendar when it can take them, else the first that can.
    public var defaultWritable: CalendarInfo? { first { $0.isDefault && $0.writable } ?? first(where: \.writable) }
}

/// Whether this process can read calendars.
public enum AccessState: Codable, Sendable, Equatable {
    case granted
    case notDetermined
    case denied
    case restricted
    /// Can add events but not read them (macOS 14's write-only access).
    case writeOnly
    /// Calendar access goes through the menu bar app, and it could not be reached.
    case unavailable(String)

    public var canRead: Bool { self == .granted }
}

/// Days as `YYYY-MM-DD` in the user's time zone.
public enum DayFormat {
    public static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func date(_ string: String, calendar: Calendar = .current) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, string.count == 10 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// "1 event", "3 events" (or the given plural: "2 matches").
public func plural(_ count: Int, _ word: String, _ pluralForm: String? = nil) -> String {
    "\(count) \(count == 1 ? word : pluralForm ?? word + "s")"
}

/// The user's answer to an invitation.
public struct InvitationAnswer: Codable, Sendable, Hashable {
    public var status: Participant.Status
    public var comment: String?
    public var span: Span

    public init(status: Participant.Status, comment: String? = nil, span: Span = .thisEvent) {
        self.status = status
        self.comment = comment
        self.span = span
    }
}

/// What Calendar allows for answering one invitation (nil: it did not say).
public struct InvitationCheck: Codable, Sendable, Hashable {
    /// Whether this macOS has the (undocumented) EventKit calls for answering.
    public var supported: Bool
    public var allowsStatusChange: Bool?
    public var allowsComment: Bool?
    /// The answer covers every occurrence of a repeating event, whatever the span.
    public var appliesToAll: Bool?

    public init(supported: Bool, allowsStatusChange: Bool? = nil, allowsComment: Bool? = nil, appliesToAll: Bool? = nil) {
        self.supported = supported
        self.allowsStatusChange = allowsStatusChange
        self.allowsComment = allowsComment
        self.appliesToAll = appliesToAll
    }

    public var answerable: Bool { supported && allowsStatusChange != false }
}
