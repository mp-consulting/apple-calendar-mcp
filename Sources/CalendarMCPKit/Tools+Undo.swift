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
            back, a deleted one is created again (without its attendees: EventKit cannot invite them).
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
                            ("span", record.span == .futureEvents ? .string("future") : nil),
                        ])
                    }))]),
                    summary: plural(recent.count, "change"))
            }
            try self.requireChanges()
            guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces)),
                let record = journal.records().first(where: { $0.id == id })
            else { throw ToolError("No change \(text) in the journal (it keeps 30 days).") }
            guard record.undone == nil else { throw ToolError("That change was already undone.") }
            let reply: ToolReply
            switch record.kind {
            case .created:
                guard let made = record.after else { throw ToolError("The journal entry is incomplete.") }
                let series = EventRef(eventID: made.eventID)
                guard let current = try self.backend.event(made.isRecurring ? series : made.ref) else {
                    journal.markUndone(id)
                    return ToolReply(json: .obj([("undone", .string("created")), ("note", .string("The event was already gone."))]), summary: "already gone")
                }
                // An event Claude made and nobody changed since goes without asking; anything else follows the delete policy.
                let untouched = current.title == made.title && current.start == made.start && current.end == made.end && !current.hasOtherAttendees
                if !untouched { try await self.authorize(tool: "undo_change", deleting: true, events: [current]) }
                try self.backend.delete(made.isRecurring ? series : made.ref, span: made.isRecurring ? .futureEvents : .thisEvent)
                reply = ToolReply(json: .obj([("undone", .string("created")), ("deleted", Render.event(current))]), summary: "deleted the event it created")
            case .updated:
                guard let before = record.before, let after = record.after else { throw ToolError("The journal entry is incomplete.") }
                let ref = after.ref
                let current = try self.event(ref)
                var change = EventChange(restoring: before)
                if before.calendarID == current.calendarID { change.calendarID = nil }
                if before.recurrence == current.recurrence {
                    change.recurrence = nil
                    change.removeRecurrence = false
                }
                try await self.authorize(tool: "undo_change", deleting: false, events: current.hasOtherAttendees ? [current] : [], detail: Self.describe(current, change.applied(to: current)))
                let restored = try self.backend.update(ref, change, span: record.span)
                reply = ToolReply(json: .obj([("undone", .string("updated")), ("event", Render.detail(restored, notesLimit: 4000))]), summary: "restored 1 event", event: restored)
            case .deleted:
                guard let before = record.before else { throw ToolError("The journal entry is incomplete.") }
                var draft = EventDraft(copying: before)
                let calendars = try self.visibleCalendars()
                if calendars.first(where: { $0.id == before.calendarID })?.writable != true {
                    draft.calendarID = calendars.defaultWritable?.id
                }
                let created = try self.backend.create(draft)
                journal.append([ChangeRecord(tool: "undo_change", kind: .created, before: nil, after: created)])
                reply = ToolReply(
                    json: .obj([
                        ("undone", .string("deleted")), ("created", Render.detail(created, notesLimit: 4000)),
                        ("note", before.hasOtherAttendees ? .string("Its attendees were not invited again (EventKit cannot); invite them in Calendar.") : nil),
                    ]),
                    summary: "brought back 1 event", event: created)
            }
            journal.markUndone(id)
            return reply
        }
    }
}
