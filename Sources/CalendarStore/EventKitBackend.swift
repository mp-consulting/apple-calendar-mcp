import AppKit
import EventKit
import Foundation

/// Calendar through EventKit in this process. Needs Calendars "Full Access" for this process's responsible app;
/// it never asks for it (only the menu bar app does, from its own bundle with its own usage description).
public final class EventKitBackend: CalendarBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var store: EKEventStore?
    private var storeAccess: AccessState?
    private var changes = 0
    private var observer: NSObjectProtocol?

    public init() {}

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public static func authorization() -> AccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    public func access() -> AccessState { Self.authorization() }

    /// Asks macOS for full access (shows the system prompt the first time). Only for an app bundle with
    /// `NSCalendarsFullAccessUsageDescription`: the menu bar app.
    public func requestAccess() async -> AccessState {
        let store = lock.withLock { self.store ?? EKEventStore() }
        _ = try? await store.requestFullAccessToEvents()
        lock.withLock {
            self.store = nil  // made again with the new permission
            storeAccess = nil
        }
        return Self.authorization()
    }

    public func changeCount() -> Int { lock.withLock { changes } }

    /// The store, made again when the permission changed since it was made (EventKit caches what it was allowed).
    private func withStore<T>(_ body: (EKEventStore) throws -> T) throws -> T {
        try lock.withLock {
            let access = Self.authorization()
            guard access == .granted else { throw CalendarError(Self.explain(access)) }
            if store == nil || storeAccess != access {
                let made = EKEventStore()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: made, queue: nil) { [weak self] _ in
                    self?.lock.withLock { self?.changes += 1 }
                }
                store = made
                storeAccess = access
            }
            return try body(store!)
        }
    }

    public static func explain(_ access: AccessState) -> String {
        switch access {
        case .granted: "Calendar access is granted."
        case .notDetermined: "Calendar access has not been asked for yet."
        case .denied: "Calendar access is turned off (System Settings › Privacy & Security › Calendars)."
        case .restricted: "Calendar access is restricted on this Mac (Screen Time or a device profile)."
        case .writeOnly: "Calendar access is \"Add Events Only\"; reading needs Full Access (System Settings › Privacy & Security › Calendars)."
        case .unavailable(let reason): reason
        }
    }

    // MARK: Reads

    public func calendars() throws -> [CalendarInfo] {
        try withStore { store in
            let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
            return store.calendars(for: .event).map { Self.info($0, defaultID: defaultID) }
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        }
    }

    public func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [Event] {
        try withStore { store in
            var calendars: [EKCalendar]?
            if let calendarIDs {
                calendars = calendarIDs.compactMap { store.calendar(withIdentifier: $0) }
                if calendars!.isEmpty { return [] }
            }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            return store.events(matching: predicate).map(Self.event).sorted(by: Event.chronological)
        }
    }

    public func event(_ ref: EventRef) throws -> Event? {
        try withStore { store in try Self.find(ref, in: store).map(Self.event) }
    }

    /// The EKEvent for `ref`: the series' first occurrence, or the occurrence starting (originally) at `ref.occurrence`.
    private static func find(_ ref: EventRef, in store: EKEventStore) throws -> EKEvent? {
        guard let first = store.event(withIdentifier: ref.eventID) else { return nil }
        guard let occurrence = ref.occurrence, first.isRecurring else { return first }
        if first.occurrenceDate == occurrence || first.startDate == occurrence { return first }
        // Occurrences live only in date queries: look around the original start (a moved one may be a day away).
        let window = max(first.endDate.timeIntervalSince(first.startDate), 3600) + 2 * 86_400
        let predicate = store.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-window), end: occurrence.addingTimeInterval(window), calendars: [first.calendar])
        return store.events(matching: predicate).first {
            $0.eventIdentifier == ref.eventID && ($0.occurrenceDate == occurrence || $0.startDate == occurrence)
        }
    }

    // MARK: Writes

    public func create(_ draft: EventDraft) throws -> Event {
        try withStore { store in
            let event = EKEvent(eventStore: store)
            if let id = draft.calendarID {
                guard let calendar = store.calendar(withIdentifier: id) else { throw CalendarError("No calendar with id \(id).") }
                event.calendar = calendar
            } else {
                guard let calendar = store.defaultCalendarForNewEvents else {
                    throw CalendarError("There is no default calendar for new events; pass calendar.")
                }
                event.calendar = calendar
            }
            try Self.requireWritable(event.calendar)
            event.title = draft.title
            event.isAllDay = draft.isAllDay
            event.startDate = draft.start
            event.endDate = draft.end
            if !draft.isAllDay { event.timeZone = draft.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }
            event.location = draft.location
            event.notes = draft.notes
            event.url = draft.url.flatMap(URL.init(string:))
            if let availability = draft.availability { event.availability = Self.ekAvailability(availability) }
            event.alarms = draft.alarms.isEmpty ? nil : draft.alarms.map(Self.ekAlarm)
            if let rule = draft.recurrence { event.recurrenceRules = [Self.ekRule(rule)] }
            do {
                try store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw CalendarError("Calendar refused the new event: \(error.localizedDescription)")
            }
            return Self.event(event)
        }
    }

    public func update(_ ref: EventRef, _ change: EventChange, span: Span) throws -> Event {
        try withStore { store in
            guard let event = try Self.find(ref, in: store) else { throw CalendarError.notFound(ref) }
            try Self.requireWritable(event.calendar)
            if let title = change.title { event.title = title }
            if let isAllDay = change.isAllDay { event.isAllDay = isAllDay }
            if let start = change.start {
                let duration = event.endDate.timeIntervalSince(event.startDate)
                event.startDate = start
                if change.end == nil { event.endDate = start.addingTimeInterval(duration) }
            }
            if let end = change.end { event.endDate = end }
            guard event.endDate >= event.startDate else { throw CalendarError.endBeforeStart }
            if let zone = change.timeZone { event.timeZone = zone.isEmpty ? nil : TimeZone(identifier: zone) }
            if let location = change.location {
                event.location = location.isEmpty ? nil : location
                event.structuredLocation = location.isEmpty ? nil : EKStructuredLocation(title: location)
            }
            if let notes = change.notes { event.notes = notes.isEmpty ? nil : notes }
            if let url = change.url { event.url = url.isEmpty ? nil : URL(string: url) }
            if let availability = change.availability { event.availability = Self.ekAvailability(availability) }
            if let alarms = change.alarms { event.alarms = alarms.isEmpty ? nil : alarms.map(Self.ekAlarm) }
            if change.removeRecurrence { event.recurrenceRules = nil }
            if let rule = change.recurrence { event.recurrenceRules = [Self.ekRule(rule)] }
            if let id = change.calendarID {
                guard let calendar = store.calendar(withIdentifier: id) else { throw CalendarError("No calendar with id \(id).") }
                try Self.requireWritable(calendar)
                event.calendar = calendar
            }
            do {
                try store.save(event, span: Self.ekSpan(span, event), commit: true)
            } catch {
                throw CalendarError("Calendar refused the change: \(error.localizedDescription)")
            }
            return Self.event(event)
        }
    }

    public func delete(_ ref: EventRef, span: Span) throws {
        try withStore { store in
            guard let event = try Self.find(ref, in: store) else { throw CalendarError.notFound(ref) }
            try Self.requireWritable(event.calendar)
            do {
                try store.remove(event, span: Self.ekSpan(span, event), commit: true)
            } catch {
                throw CalendarError("Calendar refused to delete it: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Invitations

    /// EventKit has no public call for answering an invitation; Calendar uses `-[EKEvent setParticipationStatus:]`
    /// and the account sends the answer to the organizer when the event is saved (checked with Google and iCloud,
    /// macOS 27). Each call is checked with `responds(to:)` first. `canBeRespondedTo` is false for invitations that
    /// can be answered this way, so it is not consulted: `allowsParticipationStatusModifications` is the gate.
    public func invitationCheck(_ ref: EventRef) throws -> InvitationCheck {
        try withStore { store in
            guard let event = try Self.find(ref, in: store) else { throw CalendarError.notFound(ref) }
            return Self.invitationCheck(event)
        }
    }

    public func respond(_ ref: EventRef, _ answer: InvitationAnswer) throws -> Event {
        try withStore { store in
            guard let event = try Self.find(ref, in: store) else { throw CalendarError.notFound(ref) }
            let check = Self.invitationCheck(event)
            guard check.supported else { throw CalendarError("This version of macOS does not let apps answer invitations; answer it in Calendar.") }
            guard check.answerable else { throw CalendarError("Calendar does not allow changing your answer to \"\(event.title ?? "")\".") }
            let status: EKParticipantStatus = switch answer.status {
            case .accepted: .accepted
            case .declined: .declined
            case .tentative: .tentative
            default: throw CalendarError("An answer is accepted, declined or tentative.")
            }
            event.setValue(NSNumber(value: status.rawValue), forKey: "participationStatus")
            if let comment = answer.comment, check.allowsComment != false, event.responds(to: NSSelectorFromString("setResponseComment:")) {
                event.setValue(comment.isEmpty ? nil : comment, forKey: "responseComment")
            }
            let span: EKSpan = check.appliesToAll == true ? .futureEvents : Self.ekSpan(answer.span, event)
            do {
                try store.save(event, span: span, commit: true)
            } catch {
                throw CalendarError("Calendar refused the answer: \(error.localizedDescription)")
            }
            return Self.event(event)
        }
    }

    static func invitationCheck(_ event: EKEvent) -> InvitationCheck {
        func flag(_ name: String) -> Bool? {
            event.responds(to: NSSelectorFromString(name)) ? (event.value(forKey: name) as? NSNumber)?.boolValue : nil
        }
        return InvitationCheck(
            supported: event.responds(to: NSSelectorFromString("setParticipationStatus:")),
            allowsStatusChange: flag("allowsParticipationStatusModifications"),
            allowsComment: flag("allowsResponseCommentModifications"), appliesToAll: flag("responseMustApplyToAll"))
    }

    private static func requireWritable(_ calendar: EKCalendar) throws {
        guard calendar.allowsContentModifications else { throw CalendarError.readOnly(calendar.title) }
    }

    private static func ekSpan(_ span: Span, _ event: EKEvent) -> EKSpan {
        span == .futureEvents && event.isRecurring ? .futureEvents : .thisEvent
    }

    // MARK: Conversion

    static func info(_ calendar: EKCalendar, defaultID: String?) -> CalendarInfo {
        let kind: CalendarInfo.Kind = switch calendar.type {
        case .local: .local
        case .calDAV: .calDAV
        case .exchange: .exchange
        case .subscription: .subscription
        case .birthday: .birthday
        @unknown default: .unknown
        }
        return CalendarInfo(
            id: calendar.calendarIdentifier, title: calendar.title, account: calendar.source?.title ?? "On My Mac", kind: kind,
            color: hex(calendar.cgColor), writable: calendar.allowsContentModifications, isDefault: calendar.calendarIdentifier == defaultID)
    }

    static func hex(_ color: CGColor?) -> String {
        guard let color, let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "#8E8E93" }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()).clamped(0, 255) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    static func event(_ event: EKEvent) -> Event {
        let availability: Availability = switch event.availability {
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        default: .busy
        }
        let status: EventStatus = switch event.status {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .cancelled
        default: .none
        }
        let recurring = event.isRecurring
        return Event(
            eventID: event.eventIdentifier ?? event.calendarItemIdentifier, externalID: event.calendarItemExternalIdentifier,
            calendarID: event.calendar?.calendarIdentifier ?? "", calendarTitle: event.calendar?.title ?? "", title: event.title ?? "",
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, timeZone: event.timeZone?.identifier,
            location: event.structuredLocation?.title ?? event.location, notes: event.notes, url: event.url?.absoluteString,
            availability: availability, status: status, organizer: event.organizer.map(participant),
            attendees: (event.attendees ?? []).map(participant), alarms: (event.alarms ?? []).compactMap(alarm),
            recurrence: event.recurrenceRules?.first.map(rule), isDetached: event.isDetached,
            occurrenceDate: recurring ? event.occurrenceDate : nil, created: event.creationDate, modified: event.lastModifiedDate)
    }

    static func participant(_ participant: EKParticipant) -> Participant {
        let status: Participant.Status = switch participant.participantStatus {
        case .pending: .pending
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .delegated: .delegated
        case .completed: .completed
        case .inProcess: .inProcess
        default: .unknown
        }
        let role: Participant.Role = switch participant.participantRole {
        case .required: .required
        case .optional: .optional
        case .chair: .chair
        case .nonParticipant: .nonParticipant
        default: .unknown
        }
        let kind: Participant.Kind = switch participant.participantType {
        case .person: .person
        case .room: .room
        case .resource: .resource
        case .group: .group
        default: .unknown
        }
        let url = participant.url
        let email = url.scheme?.lowercased() == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)).removingPercentEncoding : nil
        return Participant(name: participant.name, email: email, status: status, role: role, kind: kind, isCurrentUser: participant.isCurrentUser)
    }

    static func alarm(_ alarm: EKAlarm) -> Alarm? {
        if let date = alarm.absoluteDate { return Alarm(at: date) }
        return Alarm(minutesBefore: Int((-alarm.relativeOffset / 60).rounded()))
    }

    static func ekAlarm(_ alarm: Alarm) -> EKAlarm {
        if let at = alarm.at { return EKAlarm(absoluteDate: at) }
        return EKAlarm(relativeOffset: -TimeInterval((alarm.minutesBefore ?? 0) * 60))
    }

    static func ekAvailability(_ availability: Availability) -> EKEventAvailability {
        switch availability {
        case .busy: .busy
        case .free: .free
        case .tentative: .tentative
        case .unavailable: .unavailable
        }
    }

    static func rule(_ rule: EKRecurrenceRule) -> Recurrence {
        let frequency: Recurrence.Frequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        @unknown default: .daily
        }
        return Recurrence(
            frequency: frequency, interval: rule.interval, count: rule.recurrenceEnd.flatMap { $0.occurrenceCount > 0 ? $0.occurrenceCount : nil },
            until: rule.recurrenceEnd?.endDate, weekdays: rule.daysOfTheWeek?.map { $0.dayOfTheWeek.rawValue },
            monthDays: rule.daysOfTheMonth?.map(\.intValue))
    }

    static func ekRule(_ rule: Recurrence) -> EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch rule.frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let end: EKRecurrenceEnd? = rule.count.map { EKRecurrenceEnd(occurrenceCount: $0) } ?? rule.until.map { EKRecurrenceEnd(end: $0) }
        let days = rule.weekdays?.compactMap { EKWeekday(rawValue: $0).map { EKRecurrenceDayOfWeek($0) } }
        return EKRecurrenceRule(
            recurrenceWith: frequency, interval: rule.interval, daysOfTheWeek: days?.isEmpty == false ? days : nil,
            daysOfTheMonth: rule.monthDays?.map { NSNumber(value: $0) }, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: end)
    }
}

extension EKEvent {
    fileprivate var isRecurring: Bool { hasRecurrenceRules || isDetached }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}
