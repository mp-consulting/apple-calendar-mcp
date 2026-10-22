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
        /// Delete an event it created (`ask`: it changed since, or others are invited).
        case deleteCreated(ChangeRecord, current: Event, ask: Bool)
        case alreadyGone(ChangeRecord)
        case restore(ChangeRecord, current: Event, change: EventChange)
        case recreate(ChangeRecord, draft: EventDraft)
        case reminder(ChangeRecord)
    }

    private func undo(_ records: [ChangeRecord], journal: ChangeJournal) async throws -> ToolReply {
        // Check everything first, then ask once, then change: a refusal leaves every event as it is.
        var steps: [UndoStep] = []
        for record in records {
            try Task.checkCancellation()
            if record.reminderBefore != nil || record.reminderAfter != nil {
                steps.append(.reminder(record))
                continue
            }
            switch record.kind {
            case .created:
                guard let made = record.after else { throw ToolError("The journal entry is incomplete.") }
                guard let current = try backend.event(made.isRecurring ? EventRef(eventID: made.eventID) : made.ref) else {
                    steps.append(.alreadyGone(record))
                    continue
                }
                try requireWritable([current])
                // An event Claude made and nobody changed since goes without asking; anything else follows the delete policy.
                let untouched = current.title == made.title && current.start == made.start && current.end == made.end && !current.hasOtherAttendees
                steps.append(.deleteCreated(record, current: current, ask: !untouched))
            case .updated:
                guard let before = record.before, let after = record.after else { throw ToolError("The journal entry is incomplete.") }
                let current = try event(after.ref)
                try requireWritable([current])
                var change = EventChange(restoring: before)
                if before.calendarID == current.calendarID { change.calendarID = nil }
                if let target = change.calendarID, settings.current.isReadOnly(target) {
                    throw ToolError("\"\(before.title)\" came from \(before.calendarTitle), which Claude may now only read (Apple Calendar MCP settings). Nothing was changed.")
                }
                if before.recurrence == current.recurrence {
                    change.recurrence = nil
                    change.removeRecurrence = false
                }
                steps.append(.restore(record, current: current, change: change))
            case .deleted:
                guard let before = record.before else { throw ToolError("The journal entry is incomplete.") }
                var draft = EventDraft(copying: before)
                let calendars = try visibleCalendars()
                if calendars.first(where: { $0.id == before.calendarID })?.writable != true {
                    draft.calendarID = calendars.defaultWritable?.id
                }
                steps.append(.recreate(record, draft: draft))
            }
        }
        try await authorizeUndo(steps)

        var done: [JSON] = []
        var failures: [JSON] = []
        var single: ToolReply?
        for step in steps {
            try Task.checkCancellation()
            do {
                switch step {
                case let .deleteCreated(record, current, _):
                    let made = record.after!
                    try backend.delete(made.isRecurring ? EventRef(eventID: made.eventID) : made.ref, span: made.isRecurring ? .futureEvents : .thisEvent)
                    done.append(Render.event(current))
                    single = ToolReply(json: .obj([("undone", .string("created")), ("deleted", Render.event(current))]), summary: "deleted the event it created")
                case .alreadyGone:
                    single = ToolReply(json: .obj([("undone", .string("created")), ("note", .string("The event was already gone."))]), summary: "already gone")
                case let .restore(record, current, change):
                    let restored = try backend.update(current.ref, change, span: record.span)
                    done.append(Render.event(restored))
                    single = ToolReply(
                        json: .obj([("undone", .string("updated")), ("event", Render.detail(restored, notesLimit: 4000))]),
                        summary: "restored 1 event", event: restored)
                case let .recreate(record, draft):
                    let created = try backend.create(draft)
                    journal.append([ChangeRecord(tool: "undo_change", kind: .created, before: nil, after: created)])
                    done.append(Render.event(created))
                    single = ToolReply(
                        json: .obj([
                            ("undone", .string("deleted")), ("created", Render.detail(created, notesLimit: 4000)),
                            ("note", record.before!.hasOtherAttendees ? .string("Its attendees were not invited again (EventKit cannot); invite them in Calendar.") : nil),
                        ]),
                        summary: "brought back 1 event", event: created)
                case .reminder(let record):
                    single = try await undoReminder(record, journal: journal)
                    if case .object(let pairs) = single!.json, let item = pairs.first(where: { $0.0 != "undone" && $0.0 != "note" })?.1 { done.append(item) }
                }
                journal.markUndone(step.record.id)
            } catch {
                guard records.count > 1 else { throw error }
                failures.append(.obj([("title", step.record.event.map { .string($0.title) } ?? step.record.reminder.map { .string($0.title) }), ("error", .string(String(describing: error)))]))
            }
        }
        if records.count == 1, let single { return single }
        return ToolReply(
            json: .obj([
                ("undone", .string(records[0].kind.rawValue)), ("count", .int(Int64(done.count))), ("items", .array(done)),
                ("failed", failures.isEmpty ? nil : .array(failures)),
                ("note", records.contains { $0.kind == .deleted && $0.before?.hasOtherAttendees == true }
                    ? .string("Attendees were not invited again (EventKit cannot); invite them in Calendar.") : nil),
            ]),
            summary: "undid \(plural(done.count, "change"))\(failures.isEmpty ? "" : ", \(failures.count) failed")")
    }

    /// One approval for the whole undo: deleting what changed since it was made, and changing shared events.
    private func authorizeUndo(_ steps: [UndoStep]) async throws {
        let deleting = steps.compactMap { step -> Event? in
            if case let .deleteCreated(_, current, ask) = step, ask { return current }
            return nil
        }
        let restoring = steps.compactMap { step -> (Event, EventChange)? in
            if case let .restore(_, current, change) = step { return (current, change) }
            return nil
        }
        if !deleting.isEmpty { try await authorize(tool: "undo_change", deleting: true, events: deleting) }
        if !restoring.isEmpty {
            let detail = restoring.count == 1
                ? Self.describe(restoring[0].0, restoring[0].1.applied(to: restoring[0].0))
                : "Puts \(restoring.count) events back as they were."
            try await authorize(tool: "undo_change", deleting: false, events: restoring.map(\.0), detail: detail)
        }
    }
}

extension CalendarToolbox.UndoStep {
    fileprivate var record: ChangeRecord {
        switch self {
        case .deleteCreated(let record, _, _), .alreadyGone(let record), .restore(let record, _, _), .recreate(let record, _), .reminder(let record): record
        }
    }
}
