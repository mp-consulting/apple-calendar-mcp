import EventKit
import Foundation

// Reminders live in the same EventKit store as events, in lists (calendars for `.reminder`), behind a permission of
// their own. Fetching them is asynchronous only: each query waits for EventKit's callback.

extension EventKitBackend {
    public func reminderAccess() -> AccessState { Self.authorization(for: .reminder) }

    public func reminderLists() throws -> [CalendarInfo] {
        try withStore(for: .reminder) { store in
            let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
            return store.calendars(for: .reminder).map { Self.info($0, defaultID: defaultID) }
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        }
    }

    public func reminders(_ query: ReminderQuery) throws -> [Reminder] {
        try withStore(for: .reminder) { store in
            var lists: [EKCalendar]?
            if let ids = query.listIDs {
                lists = ids.compactMap { store.calendar(withIdentifier: $0) }
                if lists!.isEmpty { return [] }
            }
            var predicates: [NSPredicate] = []
            if query.status != .completed {
                // Without a window this also returns open reminders that have no due date.
                let windowed = query.dueAfter != nil || query.dueBefore != nil
                predicates.append(windowed
                    ? store.predicateForIncompleteReminders(withDueDateStarting: query.dueAfter, ending: query.dueBefore, calendars: lists)
                    : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
            }
            if query.status != .open {
                predicates.append(store.predicateForCompletedReminders(
                    withCompletionDateStarting: query.completedAfter, ending: query.completedBefore, calendars: lists))
            }
            var results: [Reminder] = []
            for predicate in predicates { results += Self.fetch(predicate, in: store).map(Self.reminder) }
            return results.filter(query.matches).sorted(by: Reminder.byDue)
        }
    }

    public func reminder(_ id: String) throws -> Reminder? {
        try withStore(for: .reminder) { store in (store.calendarItem(withIdentifier: id) as? EKReminder).map(Self.reminder) }
    }

    public func createReminder(_ draft: ReminderDraft) throws -> Reminder {
        try withStore(for: .reminder) { store in
            let reminder = EKReminder(eventStore: store)
            if let id = draft.listID {
                guard let list = store.calendar(withIdentifier: id) else { throw CalendarError("No reminder list with id \(id).") }
                reminder.calendar = list
            } else {
                guard let list = store.defaultCalendarForNewReminders() else { throw CalendarError("There is no default reminder list; pass list.") }
                reminder.calendar = list
            }
            try Self.requireWritable(reminder.calendar)
            reminder.title = draft.title
            reminder.notes = draft.notes
            reminder.url = draft.url.flatMap(URL.init(string:))
            reminder.priority = draft.priority
            Self.setDue(reminder, draft.due, hasTime: draft.dueHasTime)
            if let rule = draft.recurrence, draft.due != nil { reminder.recurrenceRules = [Self.ekRule(rule)] }
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw CalendarError("Reminders refused the new reminder: \(error.localizedDescription)")
            }
            return Self.reminder(reminder)
        }
    }

    public func updateReminder(_ id: String, _ change: ReminderChange) throws -> Reminder {
        try withStore(for: .reminder) { store in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw CalendarError.reminderNotFound(id) }
            try Self.requireWritable(reminder.calendar)
            let target = change.applied(to: Self.reminder(reminder))
            if change.title != nil { reminder.title = target.title }
            if change.notes != nil { reminder.notes = target.notes }
            if change.url != nil { reminder.url = target.url.flatMap(URL.init(string:)) }
            if change.priority != nil { reminder.priority = target.priority }
            if change.removeDue || change.due != nil || change.dueHasTime != nil { Self.setDue(reminder, target.due, hasTime: target.dueHasTime) }
            if let completed = change.completed { reminder.isCompleted = completed }
            if let listID = change.listID {
                guard let list = store.calendar(withIdentifier: listID) else { throw CalendarError("No reminder list with id \(listID).") }
                try Self.requireWritable(list)
                reminder.calendar = list
            }
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw CalendarError("Reminders refused the change: \(error.localizedDescription)")
            }
            return Self.reminder(reminder)
        }
    }

    public func deleteReminder(_ id: String) throws {
        try withStore(for: .reminder) { store in
            guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw CalendarError.reminderNotFound(id) }
            try Self.requireWritable(reminder.calendar)
            do {
                try store.remove(reminder, commit: true)
            } catch {
                throw CalendarError("Reminders refused to delete it: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Conversion

    private final class Box: @unchecked Sendable {
        var reminders: [EKReminder] = []
    }

    /// `fetchReminders` answers on a queue of its own; waits for it (a minute at most).
    static func fetch(_ predicate: NSPredicate, in store: EKEventStore) -> [EKReminder] {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        store.fetchReminders(matching: predicate) { found in
            box.reminders = found ?? []
            done.signal()
        }
        _ = done.wait(timeout: .now() + 60)
        return box.reminders
    }

    /// A due time gets an alarm at that time, as Reminders adds one; a due day gets none.
    static func setDue(_ reminder: EKReminder, _ due: Date?, hasTime: Bool) {
        reminder.alarms?.filter { $0.absoluteDate != nil }.forEach(reminder.removeAlarm)
        guard let due else {
            reminder.dueDateComponents = nil
            reminder.startDateComponents = nil
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var parts = calendar.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
        if hasTime { parts.timeZone = .current }
        reminder.dueDateComponents = parts
        if hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
    }

    static func reminder(_ reminder: EKReminder) -> Reminder {
        let parts = reminder.dueDateComponents
        let hasTime = parts?.hour != nil
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parts?.timeZone ?? .current
        let due = parts.flatMap { components -> Date? in
            var day = components
            day.calendar = nil
            return calendar.date(from: day)
        }
        return Reminder(
            id: reminder.calendarItemIdentifier, listID: reminder.calendar?.calendarIdentifier ?? "", listTitle: reminder.calendar?.title ?? "",
            title: reminder.title ?? "", notes: reminder.notes, url: reminder.url?.absoluteString, due: due, dueHasTime: hasTime,
            priority: reminder.priority, isCompleted: reminder.isCompleted, completed: reminder.completionDate,
            recurrence: reminder.recurrenceRules?.first.map(rule), created: reminder.creationDate, modified: reminder.lastModifiedDate)
    }
}
