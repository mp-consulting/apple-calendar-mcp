import Foundation

/// A reminder in the Reminders app (EventKit keeps them beside events, in lists that are calendars of their own).
public struct Reminder: Codable, Sendable, Hashable, Identifiable {
    /// EventKit's `calendarItemIdentifier`.
    public var id: String
    public var listID: String
    public var listTitle: String
    public var title: String
    public var notes: String?
    public var url: String?
    /// When it is due: a time, or a day when `dueHasTime` is false.
    public var due: Date?
    public var dueHasTime: Bool
    /// 0 none, 1–4 high, 5 medium, 6–9 low (iCalendar's scale, as Reminders uses it).
    public var priority: Int
    public var isCompleted: Bool
    public var completed: Date?
    public var recurrence: Recurrence?
    public var created: Date?
    public var modified: Date?

    public init(
        id: String, listID: String, listTitle: String, title: String, notes: String? = nil, url: String? = nil, due: Date? = nil,
        dueHasTime: Bool = false, priority: Int = 0, isCompleted: Bool = false, completed: Date? = nil, recurrence: Recurrence? = nil,
        created: Date? = nil, modified: Date? = nil
    ) {
        self.id = id
        self.listID = listID
        self.listTitle = listTitle
        self.title = title
        self.notes = notes
        self.url = url
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.isCompleted = isCompleted
        self.completed = completed
        self.recurrence = recurrence
        self.created = created
        self.modified = modified
    }

    public enum Priority: String, CaseIterable, Sendable {
        case none, high, medium, low

        public init(_ value: Int) {
            switch value {
            case 1...4: self = .high
            case 5: self = .medium
            case 6...9: self = .low
            default: self = .none
            }
        }

        /// Reminders' own values for its three marks.
        public var value: Int {
            switch self {
            case .none: 0
            case .high: 1
            case .medium: 5
            case .low: 9
            }
        }
    }

    /// Open and due by `date` (a due day without a time counts from the start of that day).
    public func isDue(by date: Date, calendar: Calendar = .current) -> Bool {
        guard !isCompleted, let due else { return false }
        return (dueHasTime ? due : calendar.startOfDay(for: due)) <= date
    }

    /// "Call the bank · due Thu 22 Oct 17:00 · Errands", for approvals and summaries.
    public var summaryLine: String {
        var parts = [title]
        if let due {
            parts.append("due " + (dueHasTime
                ? due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                : due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))))
        }
        parts.append(listTitle)
        return parts.joined(separator: " · ")
    }
}

/// Fields for a new reminder.
public struct ReminderDraft: Codable, Sendable, Hashable {
    public var title: String
    /// nil: the default list for new reminders.
    public var listID: String?
    public var notes: String?
    public var url: String?
    public var due: Date?
    public var dueHasTime: Bool
    public var priority: Int
    public var recurrence: Recurrence?

    public init(
        title: String, listID: String? = nil, notes: String? = nil, url: String? = nil, due: Date? = nil, dueHasTime: Bool = false,
        priority: Int = 0, recurrence: Recurrence? = nil
    ) {
        self.title = title
        self.listID = listID
        self.notes = notes
        self.url = url
        self.due = due
        self.dueHasTime = dueHasTime
        self.priority = priority
        self.recurrence = recurrence
    }

    public init(copying reminder: Reminder) {
        self.init(
            title: reminder.title, listID: reminder.listID, notes: reminder.notes, url: reminder.url, due: reminder.due,
            dueHasTime: reminder.dueHasTime, priority: reminder.priority, recurrence: reminder.recurrence)
    }
}

/// Changes to a reminder: nil leaves a field alone; an empty string clears a text field.
public struct ReminderChange: Codable, Sendable, Hashable {
    public var title: String?
    public var listID: String?
    public var notes: String?
    public var url: String?
    public var due: Date?
    public var dueHasTime: Bool?
    public var removeDue: Bool
    public var priority: Int?
    public var completed: Bool?

    public init(
        title: String? = nil, listID: String? = nil, notes: String? = nil, url: String? = nil, due: Date? = nil, dueHasTime: Bool? = nil,
        removeDue: Bool = false, priority: Int? = nil, completed: Bool? = nil
    ) {
        self.title = title
        self.listID = listID
        self.notes = notes
        self.url = url
        self.due = due
        self.dueHasTime = dueHasTime
        self.removeDue = removeDue
        self.priority = priority
        self.completed = completed
    }

    public var isEmpty: Bool { self == ReminderChange() }

    /// The change that puts `reminder`'s fields back as they are now.
    public init(restoring reminder: Reminder) {
        self.init(
            title: reminder.title, listID: reminder.listID, notes: reminder.notes ?? "", url: reminder.url ?? "", due: reminder.due,
            dueHasTime: reminder.dueHasTime, removeDue: reminder.due == nil, priority: reminder.priority, completed: reminder.isCompleted)
    }

    /// `reminder` with this change applied, as a backend saves it.
    public func applied(to reminder: Reminder, now: Date = Date()) -> Reminder {
        var copy = reminder
        if let title { copy.title = title }
        if let listID { copy.listID = listID }
        if let notes { copy.notes = notes.isEmpty ? nil : notes }
        if let url { copy.url = url.isEmpty ? nil : url }
        if removeDue {
            copy.due = nil
            copy.dueHasTime = false
        }
        if let due { copy.due = due }
        if let dueHasTime { copy.dueHasTime = dueHasTime }
        if let priority { copy.priority = priority }
        if let completed, completed != reminder.isCompleted {
            copy.isCompleted = completed
            copy.completed = completed ? now : nil
        }
        return copy
    }
}

/// Which reminders a query returns.
public struct ReminderQuery: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case open, completed, all
    }

    /// nil: every list.
    public var listIDs: [String]?
    public var status: Status
    /// Open reminders due in this window (nil ends: unbounded; reminders without a due date only when both are nil).
    public var dueAfter: Date?
    public var dueBefore: Date?
    /// Completed reminders completed in this window.
    public var completedAfter: Date?
    public var completedBefore: Date?

    public init(
        listIDs: [String]? = nil, status: Status = .open, dueAfter: Date? = nil, dueBefore: Date? = nil, completedAfter: Date? = nil,
        completedBefore: Date? = nil
    ) {
        self.listIDs = listIDs
        self.status = status
        self.dueAfter = dueAfter
        self.dueBefore = dueBefore
        self.completedAfter = completedAfter
        self.completedBefore = completedBefore
    }

    public func matches(_ reminder: Reminder) -> Bool {
        if let listIDs, !listIDs.contains(reminder.listID) { return false }
        switch status {
        case .open:
            guard !reminder.isCompleted else { return false }
        case .completed:
            guard reminder.isCompleted else { return false }
        case .all: break
        }
        if !reminder.isCompleted, dueAfter != nil || dueBefore != nil {
            guard let due = reminder.due else { return false }
            if let dueAfter, due < dueAfter { return false }
            if let dueBefore, due >= dueBefore { return false }
        }
        if reminder.isCompleted, completedAfter != nil || completedBefore != nil {
            guard let completed = reminder.completed else { return false }
            if let completedAfter, completed < completedAfter { return false }
            if let completedBefore, completed >= completedBefore { return false }
        }
        return true
    }
}

extension Reminder {
    /// Due first (earliest first), then without a due date, then by title.
    public static func byDue(_ a: Reminder, _ b: Reminder) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

extension Reminder {
    /// Open and past due: a due time before `now`, or a due day before today.
    public func isOverdue(at now: Date, calendar: Calendar = .current) -> Bool {
        guard !isCompleted, let due else { return false }
        return dueHasTime ? due < now : calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }
}
