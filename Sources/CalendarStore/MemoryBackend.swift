import Foundation

/// Calendars kept in memory, with EventKit's rules: repeating events expand to occurrences, a change to one
/// occurrence detaches it, read-only calendars refuse changes. Tests, screenshots and `--demo` runs use it.
public final class MemoryBackend: CalendarBackend, @unchecked Sendable {
    private enum Exception {
        case removed
        case changed(Event)
    }

    private struct Series {
        var event: Event
        var exceptions: [Date: Exception] = [:]
    }

    private let lock = NSLock()
    private var calendarList: [CalendarInfo]
    private var series: [String: Series] = [:]
    private var nextID = 1
    private var changes = 0
    private let expander: RecurrenceExpander
    private var state: AccessState = .granted

    public init(calendars: [CalendarInfo], events: [Event] = [], calendar: Calendar = .current) {
        calendarList = calendars
        expander = RecurrenceExpander(calendar: calendar)
        for event in events { add(event) }
    }

    /// Adds `event` as it is (fixtures); its `eventID` is kept.
    public func add(_ event: Event) {
        lock.withLock {
            var copy = event
            copy.occurrenceDate = nil
            series[event.eventID] = Series(event: copy)
            changes += 1
        }
    }

    /// What `access()` reports (tests of missing permission).
    public func setAccess(_ access: AccessState) { lock.withLock { state = access } }

    public func access() -> AccessState { lock.withLock { state } }

    public func calendars() throws -> [CalendarInfo] {
        try lock.withLock {
            try checkAccess()
            return calendarList
        }
    }

    public func changeCount() -> Int { lock.withLock { changes } }

    public func events(from start: Date, to end: Date, calendarIDs: [String]?) throws -> [Event] {
        try lock.withLock {
            try checkAccess()
            let wanted = calendarIDs.map(Set.init)
            var results: [Event] = []
            for item in series.values where wanted?.contains(item.event.calendarID) ?? true {
                results += occurrences(of: item, from: start, to: end)
            }
            return results.sorted(by: Event.chronological)
        }
    }

    public func event(_ ref: EventRef) throws -> Event? {
        try lock.withLock {
            try checkAccess()
            return try? occurrence(ref)
        }
    }

    public func create(_ draft: EventDraft) throws -> Event {
        try lock.withLock {
            try checkAccess()
            let calendar = try writableCalendar(draft.calendarID)
            guard draft.end >= draft.start else { throw CalendarError("The end is before the start.") }
            let id = "MEM-\(nextID)"
            nextID += 1
            let now = Date()
            let event = Event(
                eventID: id, externalID: "\(id)@memory", calendarID: calendar.id, calendarTitle: calendar.title, title: draft.title,
                start: draft.start, end: draft.end, isAllDay: draft.isAllDay, timeZone: draft.isAllDay ? nil : (draft.timeZone ?? TimeZone.current.identifier),
                location: draft.location, notes: draft.notes, url: draft.url, availability: draft.availability ?? (draft.isAllDay ? .free : .busy),
                alarms: draft.alarms, recurrence: draft.recurrence, created: now, modified: now)
            series[id] = Series(event: event)
            changes += 1
            return event.recurrence == nil ? event : first(of: Series(event: event)) ?? event
        }
    }

    public func update(_ ref: EventRef, _ change: EventChange, span: Span) throws -> Event {
        try lock.withLock {
            try checkAccess()
            guard var item = series[ref.eventID] else { throw CalendarError.notFound(ref) }
            try requireWritable(item.event.calendarID)
            let target = change.calendarID.map { try? writableCalendar($0) } ?? nil
            if change.calendarID != nil, target == nil { throw CalendarError("That calendar can't be changed or doesn't exist.") }
            func edit(_ event: Event) throws -> Event {
                var updated = change.applied(to: event)
                guard updated.end >= updated.start else { throw CalendarError("The end is before the start.") }
                if let target {
                    updated.calendarID = target.id
                    updated.calendarTitle = target.title
                }
                updated.modified = Date()
                return updated
            }
            let current = try occurrence(ref)
            changes += 1
            guard item.event.recurrence != nil else {
                item.event = try edit(item.event)
                series[ref.eventID] = item
                return item.event
            }
            let original = ref.occurrence ?? item.event.start
            switch span {
            case .thisEvent:
                guard change.recurrence == nil, !change.removeRecurrence else {
                    throw CalendarError("A repeat rule changes the series: use span \"future\".")
                }
                var updated = try edit(current)
                updated.isDetached = true
                updated.occurrenceDate = original
                item.exceptions[original] = .changed(updated)
                series[ref.eventID] = item
                return updated
            case .futureEvents:
                if original <= item.event.start {
                    // From the first occurrence: the whole series changes; its exceptions belonged to the old times.
                    item.event = try edit(item.event)
                    item.exceptions = [:]
                    series[ref.eventID] = item
                    return first(of: item) ?? item.event
                }
                // Split: the old series ends before this occurrence, a new one starts with the change and keeps
                // the occurrences the old one had left.
                let oldRule = item.event.recurrence!
                let before = expander.starts(
                    of: oldRule, seriesStart: item.event.start, duration: item.event.duration, from: item.event.start, to: original
                ).count
                item.event.recurrence?.until = dayBefore(original)
                item.event.recurrence?.count = nil
                item.exceptions = item.exceptions.filter { $0.key < original }
                series[ref.eventID] = item
                var tail = current
                tail.eventID = "MEM-\(nextID)"
                tail.externalID = "\(tail.eventID)@memory"
                nextID += 1
                tail.isDetached = false
                tail.occurrenceDate = nil
                var tailRule = oldRule
                tailRule.count = oldRule.count.map { max(1, $0 - before) }
                tail.recurrence = tailRule
                tail = try edit(tail)
                series[tail.eventID] = Series(event: tail)
                return first(of: Series(event: tail)) ?? tail
            }
        }
    }

    public func delete(_ ref: EventRef, span: Span) throws {
        try lock.withLock {
            try checkAccess()
            guard var item = series[ref.eventID] else { throw CalendarError.notFound(ref) }
            try requireWritable(item.event.calendarID)
            _ = try occurrence(ref)
            changes += 1
            guard item.event.recurrence != nil else {
                series[ref.eventID] = nil
                return
            }
            let original = ref.occurrence ?? item.event.start
            switch span {
            case .thisEvent:
                item.exceptions[original] = .removed
            case .futureEvents:
                guard original > item.event.start else {
                    series[ref.eventID] = nil
                    return
                }
                item.event.recurrence?.until = dayBefore(original)
                item.event.recurrence?.count = nil
                item.exceptions = item.exceptions.filter { $0.key < original }
            }
            series[ref.eventID] = item
        }
    }

    // MARK: Helpers (under the lock)

    /// Answers for the whole series (memory events have no per-occurrence answers).
    public func respond(_ ref: EventRef, _ answer: InvitationAnswer) throws -> InvitationResult {
        try lock.withLock {
            try checkAccess()
            guard var item = series[ref.eventID] else { throw CalendarError.notFound(ref) }
            let current = try occurrence(ref)
            let invited = current.organizer?.isCurrentUser == false && current.attendees.contains(where: \.isCurrentUser)
            let check = InvitationCheck(supported: true, allowsStatusChange: invited, allowsComment: invited, appliesToAll: true)
            guard !answer.dryRun else { return InvitationResult(event: current, check: check, answered: false) }
            guard invited else { throw CalendarError("\"\(current.title)\" is not an invitation you can answer.") }
            item.event.attendees = item.event.attendees.map { person in
                var person = person
                if person.isCurrentUser { person.status = answer.status }
                return person
            }
            item.event.modified = Date()
            series[ref.eventID] = item
            changes += 1
            return InvitationResult(event: try occurrence(ref), check: check, answered: true)
        }
    }

    private func checkAccess() throws {
        guard state == .granted else { throw CalendarError("No calendar access (\(state)).") }
    }

    private func writableCalendar(_ id: String?) throws -> CalendarInfo {
        let calendar = id.map { id in calendarList.first { $0.id == id } }
            ?? calendarList.first { $0.isDefault && $0.writable } ?? calendarList.first(where: \.writable)
        guard let calendar else { throw CalendarError("No calendar with id \(id ?? "(default)").") }
        guard calendar.writable else { throw CalendarError("\"\(calendar.title)\" is read-only.") }
        return calendar
    }

    private func requireWritable(_ id: String) throws {
        guard let calendar = calendarList.first(where: { $0.id == id }) else { return }
        guard calendar.writable else { throw CalendarError("\"\(calendar.title)\" is read-only (\(calendar.account)).") }
    }

    private func occurrences(of item: Series, from start: Date, to end: Date) -> [Event] {
        guard let rule = item.event.recurrence else {
            return item.event.overlaps(start, end) ? [item.event] : []
        }
        var results: [Event] = []
        // Moved occurrences can land in the range from outside it: look a little wider, then filter.
        let margin: TimeInterval = 366 * 86_400
        for date in expander.starts(of: rule, seriesStart: item.event.start, duration: item.event.duration, from: start.addingTimeInterval(-margin), to: end.addingTimeInterval(margin)) {
            let occurrence: Event
            switch item.exceptions[date] {
            case .removed: continue
            case .changed(let changed): occurrence = changed
            case nil: occurrence = make(item.event, at: date)
            }
            if occurrence.overlaps(start, end) { results.append(occurrence) }
        }
        return results
    }

    private func make(_ master: Event, at date: Date) -> Event {
        var copy = master
        copy.start = date
        copy.end = date.addingTimeInterval(master.duration)
        copy.occurrenceDate = date
        return copy
    }

    /// The last second of the day before `date`: `until` counts whole days, so this ends a series before `date`.
    private func dayBefore(_ date: Date) -> Date { expander.calendar.startOfDay(for: date).addingTimeInterval(-1) }

    private func first(of item: Series) -> Event? {
        occurrences(of: item, from: item.event.start, to: item.event.start.addingTimeInterval(max(item.event.duration, 1))).first
    }

    /// The event or occurrence `ref` names; throws when there is none.
    private func occurrence(_ ref: EventRef) throws -> Event {
        guard let item = series[ref.eventID] else { throw CalendarError.notFound(ref) }
        guard let rule = item.event.recurrence else { return item.event }
        let date = ref.occurrence ?? item.event.start
        switch item.exceptions[date] {
        case .removed: throw CalendarError.notFound(ref)
        case .changed(let changed): return changed
        case nil:
            let starts = expander.starts(of: rule, seriesStart: item.event.start, duration: item.event.duration, from: date, to: date.addingTimeInterval(1))
            guard starts.contains(date) else { throw CalendarError.notFound(ref) }
            return make(item.event, at: date)
        }
    }
}
