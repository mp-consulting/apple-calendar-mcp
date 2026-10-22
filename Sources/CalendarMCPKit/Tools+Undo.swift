import CalendarStore
import Foundation
import MCP

extension CalendarToolbox {
    var undoTools: [ToolDefinition] { journal == nil ? [] : [undoChange] }

    var undoChange: ToolDefinition {
        ToolDefinition(
            "undo_change", "Undo a change",
            """
            Without change_id: the recent changes made through this server (newest first), with their ids. With \
            change_id: puts that change back: a created event is deleted, a changed one gets its previous fields \
            back, a deleted one is created again (without its attendees: EventKit cannot invite them). The undo_id \
            of a call that changed several events puts all of them back, with one approval.
            """,
            Schema.object([
                "change_id": Schema.string("The change to undo (from this list, or the undo_id a change returned)"),
                "limit": Schema.integer("How many recent changes to list (default 10)", minimum: 1, maximum: 100),
            ]), kind: .change, guardsChanges: false
        ) { arguments in
            guard let journal = self.journal else { throw ToolError("Undo is off.") }
            guard let text = try arguments.string("change_id") else {
                let limit = try arguments.int("limit", default: 10, in: 1...100)
                let recent = journal.records().filter { $0.undone == nil }.suffix(limit).reversed()
                return ToolReply(
                    json: .obj([("changes", .array(recent.map { record in
                        .obj([
                            ("change_id", .string(record.id.uuidString)), ("date", Render.date(record.date)), ("tool", .string(record.tool)),
                            ("kind", .string(record.kind.rawValue)), ("event", record.event.map { .string($0.summaryLine) }),
                            ("reminder", record.reminder.map { .string($0.summaryLine) }),
                            ("span", record.span == .futureEvents ? .string("future") : nil),
                            ("group_id", record.group.map { .string($0.uuidString) }),
                        ])
                    }))]),
                    summary: plural(recent.count, "change"))
            }
            try self.requireChanges()
            let records = try Self.records(for: text, in: journal.records())
            return try await self.undo(records, journal: journal)
        }
    }

    /// The change `text` names, or every change of the call (group) it names, newest first.
    static func records(for text: String, in all: [ChangeRecord]) throws -> [ChangeRecord] {
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)) else {
            throw ToolError("No change \(text) in the journal (it keeps 30 days).")
        }
        if let record = all.first(where: { $0.id == id }) {
            guard record.undone == nil else { throw ToolError("That change was already undone.") }
            return [record]
        }
        let group = all.filter { $0.group == id }
        guard !group.isEmpty else { throw ToolError("No change \(text) in the journal (it keeps 30 days).") }
        let open = group.filter { $0.undone == nil }
        guard !open.isEmpty else { throw ToolError("Those changes were already undone.") }
        return open.reversed()
    }

    /// One change to put back, checked, before anything is done.
    fileprivate enum UndoStep {
        /// Delete what it created (`ask`: it changed since, or others are invited).
        case deleteEvent(ChangeRecord, target: EventRef, span: Span, current: Event, ask: Bool)
        case deleteReminder(ChangeRecord, current: Reminder, ask: Bool)
        case alreadyGone(ChangeRecord)
        case restoreEvent(ChangeRecord, current: Event, change: EventChange)
        case restoreReminder(ChangeRecord, current: Reminder, change: ReminderChange)
        case recreateEvent(ChangeRecord, before: Event, draft: EventDraft)
        case recreateReminder(ChangeRecord, before: Reminder, draft: ReminderDraft)

        var record: ChangeRecord {
            switch self {
            case .deleteEvent(let record, _, _, _, _), .deleteReminder(let record, _, _), .alreadyGone(let record), .restoreEvent(let record, _, _),
                .restoreReminder(let record, _, _), .recreateEvent(let record, _, _), .recreateReminder(let record, _, _):
                record
            }
        }
    }

    /// What one step did: its line in a group's reply, and the reply when it was undone alone.
    private struct Undone {
        var item: JSON
        var single: ToolReply
    }

    private func undo(_ records: [ChangeRecord], journal: ChangeJournal) async throws -> ToolReply {
        // Calendars and lists are read once, and only when a step needs them.
        var calendarCache: [CalendarInfo]?
        var listCache: [CalendarInfo]?
        func calendars() throws -> [CalendarInfo] {
            if let calendarCache { return calendarCache }
            let read = try visibleCalendars()
            calendarCache = read
            return read
        }
        func lists() throws -> [CalendarInfo] {
            if let listCache { return listCache }
            let read = try visibleLists()
            listCache = read
            return read
        }
        // Check everything first, then ask once, then change: a refusal leaves everything as it is.
        var steps: [UndoStep] = []
        for record in records {
            try Task.checkCancellation()
            steps.append(try record.isReminder ? planReminder(record, lists: lists) : planEvent(record, calendars: calendars))
        }
        try await authorizeUndo(steps)

        var done: [JSON] = []
        var failures: [JSON] = []
        var last: Undone?
        for step in steps {
            try Task.checkCancellation()
            do {
                let undone = try perform(step, journal: journal)
                done.append(undone.item)
                last = undone
                journal.markUndone(step.record.id)
            } catch {
                guard records.count > 1 else { throw error }
                failures.append(.obj([("title", .string(step.record.title)), ("error", .string(String(describing: error)))]))
            }
        }
        if records.count == 1, let last { return last.single }
        return ToolReply(
            json: .obj([
                ("undone", .string(records[0].kind.rawValue)), ("count", .int(Int64(done.count))), ("items", .array(done)),
                ("failed", failures.isEmpty ? nil : .array(failures)),
                ("note", records.contains { $0.kind == .deleted && $0.before?.hasOtherAttendees == true }
                    ? .string("Attendees were not invited again (EventKit cannot); invite them in Calendar.") : nil),
            ]),
            summary: "undid \(plural(done.count, "change"))\(failures.isEmpty ? "" : ", \(failures.count) failed")")
    }

    private func planEvent(_ record: ChangeRecord, calendars: () throws -> [CalendarInfo]) throws -> UndoStep {
        switch record.kind {
        case .created:
            guard let made = record.after else { throw ToolError("The journal entry is incomplete.") }
            // A repeating event goes as a whole series.
            let target = made.isRecurring ? EventRef(eventID: made.eventID) : made.ref
            guard let current = try backend.event(target) else { return .alreadyGone(record) }
            try requireWritable([current], in: calendars())
            // An event Claude made and nobody changed since goes without asking; anything else follows the delete policy.
            let untouched = current.title == made.title && current.start == made.start && current.end == made.end && !current.hasOtherAttendees
            return .deleteEvent(record, target: target, span: made.isRecurring ? .futureEvents : .thisEvent, current: current, ask: !untouched)
        case .updated:
            guard let before = record.before, let after = record.after else { throw ToolError("The journal entry is incomplete.") }
            let current = try event(after.ref)
            try requireWritable([current], in: calendars())
            var change = EventChange(restoring: before)
            if before.calendarID == current.calendarID { change.calendarID = nil }
            if let target = change.calendarID, try calendars().first(where: { $0.id == target })?.writable != true {
                throw ToolError("\"\(before.title)\" came from \(before.calendarTitle), which Claude may no longer change. Nothing was changed.")
            }
            if before.recurrence == current.recurrence {
                change.recurrence = nil
                change.removeRecurrence = false
            }
            return .restoreEvent(record, current: current, change: change)
        case .deleted:
            guard let before = record.before else { throw ToolError("The journal entry is incomplete.") }
            var draft = EventDraft(copying: before)
            if try calendars().first(where: { $0.id == before.calendarID })?.writable != true { draft.calendarID = try calendars().defaultWritable?.id }
            return .recreateEvent(record, before: before, draft: draft)
        }
    }

    private func planReminder(_ record: ChangeRecord, lists: () throws -> [CalendarInfo]) throws -> UndoStep {
        switch record.kind {
        case .created:
            guard let made = record.reminderAfter else { throw ToolError("The journal entry is incomplete.") }
            guard let current = try backend.reminder(made.id) else { return .alreadyGone(record) }
            try requireWritable([current], in: lists())
            return .deleteReminder(record, current: current, ask: current.title != made.title || current.due != made.due)
        case .updated:
            guard let before = record.reminderBefore, let after = record.reminderAfter else { throw ToolError("The journal entry is incomplete.") }
            let current = try reminder(after.id)
            try requireWritable([current], in: lists())
            var change = ReminderChange(restoring: before)
            if before.listID == current.listID { change.listID = nil }
            if let target = change.listID, try lists().first(where: { $0.id == target })?.writable != true {
                throw ToolError("\"\(before.title)\" came from \(before.listTitle), which Claude may no longer change. Nothing was changed.")
            }
            return .restoreReminder(record, current: current, change: change)
        case .deleted:
            guard let before = record.reminderBefore else { throw ToolError("The journal entry is incomplete.") }
            var draft = ReminderDraft(copying: before)
            if try lists().first(where: { $0.id == before.listID })?.writable != true { draft.listID = try lists().defaultWritable?.id }
            return .recreateReminder(record, before: before, draft: draft)
        }
    }

    /// One approval per kind for the whole undo: deleting what changed since it was made, and changing shared events.
    private func authorizeUndo(_ steps: [UndoStep]) async throws {
        var events: [Event] = []
        var reminders: [Reminder] = []
        var restoring: [(Event, EventChange)] = []
        for step in steps {
            switch step {
            case let .deleteEvent(_, _, _, current, ask) where ask: events.append(current)
            case let .deleteReminder(_, current, ask) where ask: reminders.append(current)
            case let .restoreEvent(_, current, change): restoring.append((current, change))
            default: break
            }
        }
        if !events.isEmpty { try await authorize(tool: "undo_change", deleting: true, events: events) }
        if !reminders.isEmpty { try await authorize(tool: "undo_change", deleting: reminders) }
        if !restoring.isEmpty {
            let detail = restoring.count == 1
                ? Self.describe(restoring[0].0, restoring[0].1.applied(to: restoring[0].0))
                : "Puts \(restoring.count) events back as they were."
            try await authorize(tool: "undo_change", deleting: false, events: restoring.map(\.0), detail: detail)
        }
    }

    private func perform(_ step: UndoStep, journal: ChangeJournal) throws -> Undone {
        func reply(_ kind: String, _ pairs: [(String, JSON?)], _ summary: String, event: Event? = nil) -> ToolReply {
            ToolReply(json: .obj([("undone", .string(kind))] + pairs), summary: summary, event: event)
        }
        switch step {
        case let .deleteEvent(_, target, span, current, _):
            try backend.delete(target, span: span)
            let item = Render.event(current)
            return Undone(item: item, single: reply("created", [("deleted", item)], "deleted the event it created"))
        case let .deleteReminder(_, current, _):
            try backend.deleteReminder(current.id)
            let item = Render.reminder(current, now: now())
            return Undone(item: item, single: reply("created", [("deleted", item)], "deleted the reminder it created"))
        case .alreadyGone(let record):
            let note = JSON.string("The \(record.isReminder ? "reminder" : "event") was already gone.")
            return Undone(item: .obj([("title", .string(record.title)), ("note", note)]), single: reply("created", [("note", note)], "already gone"))
        case let .restoreEvent(record, current, change):
            let restored = try backend.update(current.ref, change, span: record.span)
            return Undone(
                item: Render.event(restored),
                single: reply("updated", [("event", Render.detail(restored, notesLimit: 4000))], "restored 1 event", event: restored))
        case let .restoreReminder(_, current, change):
            let item = Render.reminder(try backend.updateReminder(current.id, change), now: now())
            return Undone(item: item, single: reply("updated", [("reminder", item)], "restored 1 reminder"))
        case let .recreateEvent(_, before, draft):
            let created = try backend.create(draft)
            journal.append([ChangeRecord(tool: "undo_change", kind: .created, before: nil, after: created)])
            return Undone(
                item: Render.event(created),
                single: reply(
                    "deleted",
                    [("created", Render.detail(created, notesLimit: 4000)),
                     ("note", before.hasOtherAttendees ? .string("Its attendees were not invited again (EventKit cannot); invite them in Calendar.") : nil)],
                    "brought back 1 event", event: created))
        case let .recreateReminder(_, before, draft):
            var created = try backend.createReminder(draft)
            if before.isCompleted, let done = try? backend.updateReminder(created.id, ReminderChange(completed: true)) { created = done }
            journal.append([ChangeRecord(tool: "undo_change", kind: .created, reminderBefore: nil, reminderAfter: created)])
            let item = Render.reminder(created, now: now())
            return Undone(item: item, single: reply("deleted", [("created", item)], "brought back 1 reminder"))
        }
    }
}
