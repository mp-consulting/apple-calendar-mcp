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

    /// The lists named in `lists`, else nil for "all visible".
    func listIDs(_ arguments: Arguments) throws -> [String]? {
        let names = try arguments.strings("lists")
        if names.isEmpty && settings.current.hiddenCalendars.isEmpty { return nil }
        let visible = try visibleLists()
        guard !names.isEmpty else { return visible.map(\.id) }
        return try names.map { try resolveCalendar($0, in: visible, noun: "reminder list").id }
    }

    /// A list the user lets Claude change, by name; the default one when none is named.
    func targetList(_ arguments: Arguments) throws -> CalendarInfo {
        let visible = try visibleLists()
        let list: CalendarInfo
        if let name = try arguments.string("list") {
            list = try resolveCalendar(name, in: visible, noun: "reminder list")
        } else {
            guard let preferred = visible.defaultWritable else { throw ToolError("No reminder list can take new reminders; pass list.") }
            list = preferred
        }
        guard list.writable else {
            let why = settings.current.isReadOnly(list.id) ? "Claude may only read it (Apple Calendar MCP settings)" : "it is read-only"
            throw ToolError("\"\(list.title)\": \(why); pick another list.")
        }
        return list
    }

    /// The reminder `id` names, when its list is visible.
    func reminder(_ id: String) throws -> Reminder {
        guard let reminder = try backend.reminder(id), !settings.current.isHidden(reminder.listID) else {
            throw ToolError(CalendarError.reminderNotFound(id).description)
        }
        return reminder
    }

    func requireWritable(_ reminders: [Reminder], nothing: String = "Nothing was changed.") throws {
        let lists = try backend.reminderLists()
        for reminder in reminders {
            if settings.current.isReadOnly(reminder.listID) {
                throw ToolError("\"\(reminder.title)\" is in \(reminder.listTitle), which Claude may only read (Apple Calendar MCP settings). \(nothing)")
            }
            if lists.first(where: { $0.id == reminder.listID })?.writable == false {
                throw ToolError("\"\(reminder.title)\" is in a read-only list (\(reminder.listTitle)). \(nothing)")
            }
        }
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
            let query = ReminderQuery(
                listIDs: try self.listIDs(arguments), status: status, dueAfter: try arguments.date("due_after"),
                dueBefore: try arguments.date("due_before", endOfDay: arguments.isDay("due_before")).map { $0.addingTimeInterval(1) },
                completedAfter: try arguments.date("completed_since") ?? self.startOfToday.addingTimeInterval(-30 * 86_400))
            var reminders = try self.backend.reminders(query).filter { !self.settings.current.isHidden($0.listID) }
            if let words = try arguments.string("query") {
                let terms = words.split(whereSeparator: \.isWhitespace)
                reminders = reminders.filter { reminder in
                    let text = reminder.title + "\n" + (reminder.notes ?? "")
                    return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                }
            }
            let limit = try arguments.int("limit", default: 100, in: 1...1000)
            let lists = try self.visibleLists()
            return ToolReply(
                json: .obj([
                    ("lists", .array(lists.map { list in
                        .obj([("id", .string(list.id)), ("title", .string(list.title)), ("account", .string(list.account)),
                              ("read_only", list.writable ? nil : .bool(true)), ("default", list.isDefault ? .bool(true) : nil)])
                    })),
                    ("count", .int(Int64(reminders.count))),
                    ("reminders", .array(reminders.prefix(limit).map { Render.reminder($0, now: self.now()) })),
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
            try self.requireWritable([current])
            let clearsDue = (try arguments.clearableString("due")) == ""
            let due = clearsDue ? nil : try self.due(arguments)
            var change = ReminderChange(
                title: try arguments.string("title"), notes: try arguments.clearableString("notes"), url: try arguments.clearableString("url"),
                due: due?.date, dueHasTime: due?.hasTime, removeDue: clearsDue, priority: try self.priority(arguments),
                completed: try arguments.bool("completed"))
            if arguments.has("list") {
                let target = try self.targetList(arguments)
                if target.id != current.listID { change.listID = target.id }
            }
            guard !change.isEmpty else { throw ToolError("Nothing to change: pass at least one field (title, due, completed, …)") }
            var preview = change.applied(to: current, now: self.now())
            if let listID = change.listID, let list = try self.visibleLists().first(where: { $0.id == listID }) { preview.listTitle = list.title }
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
            let approval = self.approval(deleting: true, events: [])
            if try arguments.bool("dry_run") == true {
                let pairs: [(String, JSON?)] = switch approval {
                case .allow: []
                case .ask: [("asks_first", .bool(true))]
                case .refuse: [("would_refuse", .string(Self.remindersRefused))]
                }
                return ToolReply(
                    json: .obj([("dry_run", .bool(true)), ("would_delete", .array(reminders.map { Render.reminder($0, now: self.now()) }))] + pairs),
                    summary: "dry run: \(plural(reminders.count, "reminder"))")
            }
            try await self.authorizeDeleting(reminders, tool: "delete_reminders")
            let group = UUID()
            var deleted: [Reminder] = []
            var records: [ChangeRecord] = []
            var failures: [JSON] = []
            for reminder in reminders {
                try Task.checkCancellation()
                do {
                    try self.backend.deleteReminder(reminder.id)
                    deleted.append(reminder)
                    records.append(ChangeRecord(tool: "delete_reminders", kind: .deleted, reminderBefore: reminder, reminderAfter: nil, group: group))
                } catch {
                    failures.append(.obj([("id", .string(reminder.id)), ("error", .string(String(describing: error)))]))
                }
            }
            self.record(records)
            return ToolReply(
                json: .obj([
                    ("deleted", .array(deleted.map { Render.reminder($0, now: self.now()) })), ("failed", failures.isEmpty ? nil : .array(failures)),
                    ("undo_id", self.undoID(records, group: group)),
                ]),
                summary: "deleted \(plural(deleted.count, "reminder"))\(failures.isEmpty ? "" : ", \(failures.count) failed")")
        }
    }

    static let remindersRefused = "Deleting is turned off (delete policy \"never\"). Nothing was deleted."

    /// The delete policy, for reminders: asks in the app unless it allows or refuses.
    func authorizeDeleting(_ reminders: [Reminder], tool: String) async throws {
        switch approval(deleting: true, events: []) {
        case .allow: return
        case .refuse: throw ToolError(Self.remindersRefused)
        case .ask: break
        }
        try await ask(ApprovalRequest(
            tool: tool, client: clientName, kind: .delete, title: reminders.count == 1 ? reminders[0].title : "\(reminders.count) reminders",
            items: Self.lines(reminders.map(\.summaryLine)), subject: "reminder"))
    }

    // MARK: Undo

    /// Puts one reminder change back.
    func undoReminder(_ record: ChangeRecord, journal: ChangeJournal) async throws -> ToolReply {
        switch record.kind {
        case .created:
            guard let made = record.reminderAfter else { throw ToolError("The journal entry is incomplete.") }
            guard let current = try backend.reminder(made.id) else {
                return ToolReply(json: .obj([("undone", .string("created")), ("note", .string("The reminder was already gone."))]), summary: "already gone")
            }
            try requireWritable([current])
            if current.title != made.title || current.due != made.due { try await authorizeDeleting([current], tool: "undo_change") }
            try backend.deleteReminder(current.id)
            return ToolReply(json: .obj([("undone", .string("created")), ("deleted", Render.reminder(current, now: now()))]), summary: "deleted the reminder it created")
        case .updated:
            guard let before = record.reminderBefore, let after = record.reminderAfter else { throw ToolError("The journal entry is incomplete.") }
            let current = try reminder(after.id)
            try requireWritable([current])
            var change = ReminderChange(restoring: before)
            if before.listID == current.listID { change.listID = nil }
            if let target = change.listID, settings.current.isReadOnly(target) {
                throw ToolError("\"\(before.title)\" came from \(before.listTitle), which Claude may now only read. Nothing was changed.")
            }
            let restored = try backend.updateReminder(current.id, change)
            return ToolReply(json: .obj([("undone", .string("updated")), ("reminder", Render.reminder(restored, now: now()))]), summary: "restored 1 reminder")
        case .deleted:
            guard let before = record.reminderBefore else { throw ToolError("The journal entry is incomplete.") }
            var draft = ReminderDraft(copying: before)
            let lists = try visibleLists()
            if lists.first(where: { $0.id == before.listID })?.writable != true { draft.listID = lists.defaultWritable?.id }
            let created = try backend.createReminder(draft)
            if before.isCompleted { _ = try? backend.updateReminder(created.id, ReminderChange(completed: true)) }
            journal.append([ChangeRecord(tool: "undo_change", kind: .created, reminderBefore: nil, reminderAfter: created)])
            return ToolReply(json: .obj([("undone", .string("deleted")), ("created", Render.reminder(created, now: now()))]), summary: "brought back 1 reminder")
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
