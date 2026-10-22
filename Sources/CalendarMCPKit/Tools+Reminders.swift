import CalendarStore
import Foundation
import MCP

extension CalendarToolbox {
    var reminderTools: [ToolDefinition] { [listReminders, createReminder, updateReminder, deleteReminders] }

    static let listsProperty = Schema.strings("Reminder lists by id, title, or Account/Title (default: all, except those hidden in settings)")
    static let priorityProperty = Schema.string("Priority", enum: Reminder.Priority.allCases.map(\.rawValue))

    /// Reminder lists Claude may see (hidden ones left out, read-only ones marked).
    func visibleLists() throws -> [CalendarInfo] {
        settings.current.visible(try backend.reminderLists())
    }

    /// A list the user lets Claude change, by name; the default one when none is named.
    func targetList(_ arguments: Arguments, in lists: [CalendarInfo]? = nil) throws -> CalendarInfo {
        try target(arguments, key: "list", in: lists ?? visibleLists(), noun: "reminder list")
    }

    /// Reminders matching `query`, those in hidden lists left out.
    func visibleReminders(_ query: ReminderQuery) throws -> [Reminder] {
        let current = settings.current
        return try backend.reminders(query).filter { !current.isHidden($0.listID) }
    }

    /// The reminder `id` names, when its list is visible.
    func reminder(_ id: String) throws -> Reminder {
        guard let reminder = try backend.reminder(id), !settings.current.isHidden(reminder.listID) else {
            throw ToolError(CalendarError.reminderNotFound(id).description)
        }
        return reminder
    }

    func requireWritable(_ reminders: [Reminder], in lists: [CalendarInfo]? = nil, nothing: String = "Nothing was changed.") throws {
        try requireWritable(reminders.map { ($0.title, $0.listID, $0.listTitle) }, in: lists ?? visibleLists(), nothing: nothing)
    }

    /// `due` as a date, and whether it has a time (a day alone is due that day).
    func due(_ arguments: Arguments) throws -> (date: Date, hasTime: Bool)? {
        guard let date = try arguments.date("due") else { return nil }
        return (date, !(try arguments.isDay("due")))
    }

    func priority(_ arguments: Arguments) throws -> Int? {
        guard let text = try arguments.string("priority") else { return nil }
        guard let priority = Reminder.Priority(rawValue: text.lowercased()) else { throw ToolError("priority must be none, high, medium or low") }
        return priority.value
    }

    // MARK: list_reminders

    var listReminders: ToolDefinition {
        ToolDefinition(
            "list_reminders", "List reminders",
            """
            Reminders from the Reminders app, open ones by default, due first. due_before and due_after limit them to \
            a window (those without a due date are then left out); status completed lists what was done (default: \
            the last 30 days). Also returns the reminder lists. Needs Reminders access in the Apple Calendar MCP app.
            """,
            Schema.object([
                "lists": Self.listsProperty,
                "status": Schema.string("open (default), completed or all", enum: ReminderQuery.Status.allCases.map(\.rawValue)),
                "due_before": Schema.string("Due before this: \(Schema.date); a day means through that day"),
                "due_after": Schema.string("Due from this"),
                "completed_since": Schema.string("Completed reminders: done since this (default: 30 days ago)"),
                "query": Schema.string("Words to find in the title or notes"),
                "limit": Schema.integer("Most reminders to return (default 100)", minimum: 1, maximum: 1000),
                "time_zone": Self.zoneProperty,
            ]), kind: .read
        ) { arguments in
            guard let status = ReminderQuery.Status(rawValue: try arguments.string("status")?.lowercased() ?? "open") else {
                throw ToolError("status must be open, completed or all")
            }
            let lists = try self.visibleLists()
            let query = ReminderQuery(
                listIDs: try self.containerIDs(arguments, key: "lists", noun: "reminder list", visible: { lists }), status: status,
                dueAfter: try arguments.date("due_after"),
                dueBefore: try arguments.date("due_before", endOfDay: arguments.isDay("due_before")).map { $0.addingTimeInterval(1) },
                completedAfter: try arguments.date("completed_since") ?? self.startOfToday.addingTimeInterval(-30 * 86_400))
            var reminders = try self.visibleReminders(query)
            if let words = try arguments.string("query") {
                reminders = reminders.filter { EventText.matches(text: $0.title + "\n" + ($0.notes ?? ""), words) }
            }
            let limit = try arguments.int("limit", default: 100, in: 1...1000)
            let now = self.now()
            return ToolReply(
                json: .obj([
                    ("lists", .array(lists.map(Render.calendar))),
                    ("count", .int(Int64(reminders.count))),
                    ("reminders", .array(reminders.prefix(limit).map { Render.reminder($0, now: now) })),
                    ("truncated", reminders.count > limit ? .bool(true) : nil),
                ]),
                summary: plural(reminders.count, "reminder"))
        }
    }

    // MARK: create_reminder

    var createReminder: ToolDefinition {
        ToolDefinition(
            "create_reminder", "Create reminder",
            """
            Add a reminder to the Reminders app: a due day (YYYY-MM-DD) or a due time (which also alerts then), in the \
            default list unless list is given. Use dry_run to preview.
            """,
            Schema.object([
                "title": Schema.string("What to do"),
                "list": Schema.string("Reminder list by id, title, or Account/Title (default: the default list)"),
                "due": Schema.string("Due: a day (YYYY-MM-DD) or a time (YYYY-MM-DDTHH:MM, local), or today/tomorrow"),
                "notes": Schema.string("Notes"),
                "url": Schema.string("A link"),
                "priority": Self.priorityProperty,
                "repeat": Self.repeatProperty,
                "time_zone": Self.zoneProperty,
                "dry_run": Schema.boolean("Show what would be added without adding it"),
            ], required: ["title"]), kind: .change
        ) { arguments in
            let list = try self.targetList(arguments)
            let due = try self.due(arguments)
            let recurrence = try self.recurrence(arguments)
            if recurrence != nil, due == nil { throw ToolError("A repeating reminder needs a due date.") }
            let draft = ReminderDraft(
                title: try arguments.requiredString("title"), listID: list.id, notes: try arguments.string("notes"), url: try arguments.string("url"),
                due: due?.date, dueHasTime: due?.hasTime ?? false, priority: try self.priority(arguments) ?? 0, recurrence: recurrence)
            if try arguments.bool("dry_run") == true {
                let preview = Reminder(
                    id: "(new)", listID: list.id, listTitle: list.title, title: draft.title, notes: draft.notes, url: draft.url, due: draft.due,
                    dueHasTime: draft.dueHasTime, priority: draft.priority, recurrence: draft.recurrence)
                return ToolReply(json: .obj([("dry_run", .bool(true)), ("would_create", Render.reminder(preview, now: self.now(), withID: false))]), summary: "dry run: 1 reminder")
            }
            let created = try self.backend.createReminder(draft)
            let record = ChangeRecord(tool: "create_reminder", kind: .created, reminderBefore: nil, reminderAfter: created)
            self.record([record])
            return ToolReply(
                json: .obj([("created", Render.reminder(created, now: self.now())), ("undo_id", self.undoID(record))]),
                summary: "created 1 reminder")
        }
    }

    // MARK: update_reminder

    var updateReminder: ToolDefinition {
        ToolDefinition(
            "update_reminder", "Update reminder",
            """
            Change a reminder, or mark it done (completed true) or not done again: only the fields given change. due "" \
            removes the due date.
            """,
            Schema.object([
                "id": Schema.string("The reminder id (from list_reminders)"),
                "title": Schema.string("What to do"),
                "list": Schema.string("Move it to this reminder list"),
                "due": Schema.string("Due: a day or a time (\"\" removes it)"),
                "notes": Schema.string("Notes (\"\" clears them)"),
                "url": Schema.string("A link (\"\" clears it)"),
                "priority": Self.priorityProperty,
                "completed": Schema.boolean("Done (true) or not done (false)"),
                "time_zone": Self.zoneProperty,
                "dry_run": Schema.boolean("Show what would change without changing it"),
            ], required: ["id"]), kind: .change, idempotent: true
        ) { arguments in
            let current = try self.reminder(try arguments.requiredString("id"))
            let lists = try self.visibleLists()
            try self.requireWritable([current], in: lists)
            let clearsDue = (try arguments.clearableString("due")) == ""
            let due = clearsDue ? nil : try self.due(arguments)
            var change = ReminderChange(
                title: try arguments.string("title"), notes: try arguments.clearableString("notes"), url: try arguments.clearableString("url"),
                due: due?.date, dueHasTime: due?.hasTime, removeDue: clearsDue, priority: try self.priority(arguments),
                completed: try arguments.bool("completed"))
            var preview = current
            if arguments.has("list") {
                let target = try self.targetList(arguments, in: lists)
                if target.id != current.listID {
                    change.listID = target.id
                    preview.listTitle = target.title
                }
            }
            guard !change.isEmpty else { throw ToolError("Nothing to change: pass at least one field (title, due, completed, …)") }
            preview = change.applied(to: preview, now: self.now())
            if try arguments.bool("dry_run") == true {
                return ToolReply(
                    json: .obj([("dry_run", .bool(true)), ("reminder", Render.reminder(current, now: self.now())), ("after", Render.reminder(preview, now: self.now()))]),
                    summary: "dry run: 1 reminder")
            }
            let updated = try self.backend.updateReminder(current.id, change)
            let record = ChangeRecord(tool: "update_reminder", kind: .updated, reminderBefore: current, reminderAfter: updated)
            self.record([record])
            return ToolReply(
                json: .obj([("updated", Render.reminder(updated, now: self.now())), ("undo_id", self.undoID(record))]),
                summary: change.completed == true ? "completed 1 reminder" : "updated 1 reminder")
        }
    }

    // MARK: delete_reminders

    var deleteReminders: ToolDefinition {
        ToolDefinition(
            "delete_reminders", "Delete reminders",
            """
            Delete reminders (to mark one done, use update_reminder with completed instead). Follows the delete \
            policy: by default the user approves in the menu bar app; undo_change brings them back.
            """,
            Schema.object([
                "ids": Schema.ids("Reminder ids (from list_reminders)"),
                "dry_run": Schema.boolean("List what would be deleted without deleting"),
            ], required: ["ids"]), kind: .change, destructive: true
        ) { arguments in
            var seen = Set<String>()
            let ids = try arguments.strings("ids").filter { seen.insert($0).inserted }
            guard !ids.isEmpty else { throw ToolError("ids is required") }
            try self.checkBatch(ids.count)
            let reminders = try ids.map(self.reminder)
            try self.requireWritable(reminders, nothing: "Nothing was deleted.")
            let now = self.now()
            if try arguments.bool("dry_run") == true {
                return ToolReply(
                    json: .obj([("dry_run", .bool(true)), ("would_delete", .array(reminders.map { Render.reminder($0, now: now) }))]
                        + self.approvalPairs(deleting: true, events: [])),
                    summary: "dry run: \(plural(reminders.count, "reminder"))")
            }
            try await self.authorize(tool: "delete_reminders", deleting: reminders)
            let applied = try self.applyEach(reminders, label: { [("id", .string($0.id)), ("title", .string($0.title))] }) { reminder, group in
                try self.backend.deleteReminder(reminder.id)
                return (reminder, ChangeRecord(tool: "delete_reminders", kind: .deleted, reminderBefore: reminder, reminderAfter: nil, group: group))
            }
            return ToolReply(
                json: .obj([("deleted", .array(applied.done.map { Render.reminder($0, now: now) }))] + self.outcome(applied)),
                summary: Self.summary("deleted", "reminder", applied))
        }
    }
}

extension Render {
    static func reminder(_ reminder: Reminder, now: Date, withID: Bool = true) -> JSON {
        let priority = Reminder.Priority(reminder.priority)
        let due: JSON? = reminder.due.map { reminder.dueHasTime ? date($0) : day($0) }
        return .obj([
            ("id", withID ? .string(reminder.id) : nil),
            ("title", .string(reminder.title)),
            ("list", .string(reminder.listTitle)),
            ("due", due),
            ("overdue", reminder.isOverdue(at: now) ? .bool(true) : nil),
            ("priority", priority == .none ? nil : .string(priority.rawValue)),
            ("completed", reminder.isCompleted ? (reminder.completed.map(date) ?? .bool(true)) : nil),
            ("repeat", reminder.recurrence.map { .string($0.summary) }),
            ("notes", reminder.notes.flatMap { $0.isEmpty ? nil : .string(truncate($0, 500)) }),
            ("url", reminder.url.map(JSON.string)),
        ])
    }
}
