import CalendarStore
import Foundation
import MCP

extension CalendarToolbox {
    var batchTools: [ToolDefinition] { [createEvents, updateEvents] }

    /// The objects of the list `key`, each read like a tool's own arguments (`time_zone` per item, else the call's).
    func items(_ arguments: Arguments, _ key: String) throws -> [Arguments] {
        guard case .array(let values)? = arguments.values[key], !values.isEmpty else { throw ToolError("\(key) must be a list of objects") }
        try checkBatch(values.count)
        return try values.enumerated().map { index, value in
            guard case .object(let fields) = value else { throw ToolError("\(key)[\(index)] must be an object") }
            var item = Arguments(fields)
            item.now = arguments.now
            item.timeZone = arguments.timeZone
            if let zone = try item.string("time_zone") {
                guard let timeZone = TimeZone(identifier: zone) else { throw ToolError("\(key)[\(index)].time_zone \"\(zone)\" is not a time zone") }
                item.timeZone = timeZone
            }
            return item
        }
    }

    /// Runs `body` for each item, naming the item in an error ("events[2]: end must be after start").
    func each<T>(_ items: [Arguments], _ key: String, _ body: (Arguments) throws -> T) throws -> [T] {
        try items.enumerated().map { index, item in
            do { return try body(item) } catch { throw ToolError("\(key)[\(index)]: \(error)") }
        }
    }

    static func list(of properties: [String: Value], required: [String], _ description: String) -> Value {
        var item = properties
        item["dry_run"] = nil
        return .object([
            "type": "array", "minItems": 1, "description": .string(description), "items": Schema.object(item, required: required),
        ])
    }

    // MARK: create_events

    var createEvents: ToolDefinition {
        ToolDefinition(
            "create_events", "Create events",
            """
            Add several events in one call (a week's focus blocks, a trip's flights and hotel, a series of sessions), \
            each with the fields of create_event. Every event is checked before any is added, and one undo_id puts \
            them all back. Use dry_run to preview.
            """,
            Schema.object([
                "events": Self.list(of: Self.changeProperties, required: ["title", "start"], "The events to add, each like create_event's arguments"),
                "dry_run": Schema.boolean("Show what would be added without adding anything"),
            ], required: ["events"]), kind: .change
        ) { arguments in
            let planned = try self.each(try self.items(arguments, "events"), "events", self.newEvent)
            if try arguments.bool("dry_run") == true {
                return ToolReply(
                    json: .obj([("dry_run", .bool(true)), ("would_create", .array(planned.map { Self.preview($0.0, in: $0.1) }))]),
                    summary: "dry run: \(plural(planned.count, "event"))")
            }
            let group = UUID()
            var created: [Event] = []
            var records: [ChangeRecord] = []
            var failures: [JSON] = []
            for (index, (draft, _)) in planned.enumerated() {
                try Task.checkCancellation()
                do {
                    let event = try self.backend.create(draft)
                    created.append(event)
                    records.append(ChangeRecord(tool: "create_events", kind: .created, before: nil, after: event, group: group))
                } catch {
                    failures.append(.obj([("index", .int(Int64(index))), ("title", .string(draft.title)), ("error", .string(String(describing: error)))]))
                }
            }
            self.record(records)
            return ToolReply(
                json: .obj([
                    ("created", .array(created.map(Render.event))), ("failed", failures.isEmpty ? nil : .array(failures)),
                    ("undo_id", self.undoID(records, group: group)),
                ]),
                summary: "created \(plural(created.count, "event"))\(failures.isEmpty ? "" : ", \(failures.count) failed")", event: created.first)
        }
    }

    // MARK: update_events

    var updateEvents: ToolDefinition {
        var properties = Self.changeProperties
        properties["id"] = Schema.string("The event id; for one occurrence of a repeating event, its occurrence id")
        properties["span"] = Self.spanProperty
        properties["remove_repeat"] = Schema.boolean("Stop the event repeating (with span future)")
        return ToolDefinition(
            "update_events", "Update events",
            """
            Change or move several events in one call (push an afternoon back an hour, move a week's meetings, rename \
            a set), each with the fields of update_event. Every change is checked before any is made; events other \
            people are invited to are approved together in one request, and one undo_id puts them all back.
            """,
            Schema.object([
                "changes": Self.list(of: properties, required: ["id"], "The changes, each like update_event's arguments"),
                "dry_run": Schema.boolean("Show what would change without changing anything"),
            ], required: ["changes"]), kind: .change, idempotent: true
        ) { arguments in
            let plans = try self.each(try self.items(arguments, "changes"), "changes", self.plannedUpdate)
            var seen = Set<String>()
            if let twice = plans.first(where: { !seen.insert($0.ref.string).inserted }) {
                throw ToolError("\"\(twice.current.title)\" is changed twice; give each event once.")
            }
            let events = plans.map(\.current)
            if try arguments.bool("dry_run") == true {
                return ToolReply(
                    json: .obj([
                        ("dry_run", .bool(true)),
                        ("would_change", .array(plans.map { .obj([("event", Render.event($0.current)), ("change", .string($0.description))]) })),
                    ] + self.approvalPairs(deleting: false, events: events)),
                    summary: "dry run: \(plural(plans.count, "event"))")
            }
            let lines = plans.prefix(8).map { "\($0.current.title): \($0.description.prefix(1).lowercased() + $0.description.dropFirst())" }
            let detail = plans.count == 1 ? plans[0].description : (lines + (plans.count > 8 ? ["… and \(plans.count - 8) more"] : [])).joined(separator: "\n")
            try await self.authorize(tool: "update_events", deleting: false, events: events, detail: detail)
            let group = UUID()
            var updated: [Event] = []
            var records: [ChangeRecord] = []
            var failures: [JSON] = []
            for plan in plans {
                try Task.checkCancellation()
                do {
                    let event = try self.backend.update(plan.ref, plan.change, span: plan.span)
                    updated.append(event)
                    records.append(ChangeRecord(tool: "update_events", kind: .updated, span: plan.span, before: plan.current, after: event, group: group))
                } catch {
                    failures.append(.obj([("id", .string(plan.ref.string)), ("title", .string(plan.current.title)), ("error", .string(String(describing: error)))]))
                }
            }
            self.record(records)
            return ToolReply(
                json: .obj([
                    ("updated", .array(updated.map(Render.event))), ("failed", failures.isEmpty ? nil : .array(failures)),
                    ("undo_id", self.undoID(records, group: group)),
                ]),
                summary: "updated \(plural(updated.count, "event"))\(failures.isEmpty ? "" : ", \(failures.count) failed")", event: updated.first)
        }
    }
}
