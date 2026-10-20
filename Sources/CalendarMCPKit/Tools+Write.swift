import CalendarStore
import Foundation
import MCP

extension CalendarToolbox {
    var changeTools: [ToolDefinition] { [createEvent, updateEvent, deleteEvent] }

    static let repeatProperty: Value = .object([
        "type": "object",
        "description": "Repeat rule",
        "properties": [
            "frequency": Schema.string("How often", enum: ["daily", "weekly", "monthly", "yearly"]),
            "interval": Schema.integer("Every this many days/weeks/months/years (default 1)", minimum: 1, maximum: 1000),
            "count": Schema.integer("Stop after this many occurrences", minimum: 1, maximum: 10_000),
            "until": Schema.string("Stop after this day, YYYY-MM-DD"),
            "weekdays": Schema.strings("Weekly: the days, mon … sun"),
            "month_days": Schema.integers("Monthly: days of the month (-1 is the last)"),
        ],
        "required": ["frequency"],
        "additionalProperties": false,
    ])

    static let changeProperties: [String: Value] = [
        "title": Schema.string("Title"),
        "start": Schema.string("Start: \(Schema.date). A day alone (YYYY-MM-DD) makes an all-day event"),
        "end": Schema.string("End; for an all-day event, the last day (inclusive)"),
        "duration_minutes": Schema.integer("Length, instead of end", minimum: 1, maximum: 60 * 24 * 60),
        "all_day": Schema.boolean("All-day event"),
        "calendar": Schema.string("Calendar by id, title, or Account/Title (default: the default calendar for new events)"),
        "location": Schema.string("Place or address (\"\" clears it)"),
        "notes": Schema.string("Notes (\"\" clears them)"),
        "url": Schema.string("A link, e.g. the video call (\"\" clears it)"),
        "alarms": Schema.integers("Reminders, in minutes before the start, e.g. [10, 1440] ([] removes them)"),
        "availability": Schema.string("How it shows in free/busy (default busy; all-day events free)", enum: Availability.allCases.map(\.rawValue)),
        "repeat": repeatProperty,
        "time_zone": zoneProperty,
        "dry_run": Schema.boolean("Show what would happen without changing anything"),
    ]

    // MARK: Argument helpers

    func recurrence(_ arguments: Arguments) throws -> Recurrence? {
        guard arguments.has("repeat") else { return nil }
        guard case .object(let fields) = arguments.values["repeat"] else { throw ToolError("repeat must be an object with a frequency") }
        var nested = Arguments(fields)
        nested.timeZone = arguments.timeZone
        nested.now = arguments.now
        guard let frequency = Recurrence.Frequency(rawValue: try nested.requiredString("frequency").lowercased()) else {
            throw ToolError("repeat.frequency must be daily, weekly, monthly or yearly")
        }
        return Recurrence(
            frequency: frequency, interval: try nested.int("interval", default: 1, in: 1...1000),
            count: try nested.int("count").map { min(max($0, 1), 10_000) }, until: try nested.date("until", endOfDay: true),
            weekdays: try nested.weekdays("weekdays"), monthDays: try nested.ints("month_days"))
    }

    func availability(_ arguments: Arguments) throws -> Availability? {
        guard let text = try arguments.string("availability") else { return nil }
        guard let value = Availability(rawValue: text.lowercased()) else { throw ToolError("availability must be busy, free, tentative or unavailable") }
        return value
    }

    func alarms(_ arguments: Arguments) throws -> [Alarm]? {
        try arguments.ints("alarms")?.map { minutes in
            guard (0...40_320).contains(minutes) else { throw ToolError("alarms are minutes before the start, 0 to 40320") }
            return Alarm(minutesBefore: minutes)
        }
    }

    /// A calendar the user may change, by name; nil for the default one (checked visible and writable).
    func targetCalendar(_ arguments: Arguments) throws -> CalendarInfo {
        let visible = try visibleCalendars()
        let calendar: CalendarInfo
        if let name = try arguments.string("calendar") {
            calendar = try resolveCalendar(name, in: visible)
        } else {
            guard let preferred = visible.first(where: { $0.isDefault && $0.writable }) ?? visible.first(where: \.writable) else {
                throw ToolError("No calendar can take new events; pass calendar (see list_calendars).")
            }
            calendar = preferred
        }
        guard calendar.writable else { throw ToolError("\"\(calendar.title)\" (\(calendar.account)) is read-only; pick another calendar.") }
        return calendar
    }

    /// Start and end from the arguments, for a new event or on top of `current`.
    func times(_ arguments: Arguments, current: Event?) throws -> (start: Date?, end: Date?, allDay: Bool?) {
        let calendar = arguments.calendar
        let startGiven = try arguments.date("start")
        let explicitAllDay = try arguments.bool("all_day")
        let startIsDay = try arguments.isDay("start")
        let endIsDay = try arguments.isDay("end")
        let allDay = explicitAllDay ?? (startGiven != nil && startIsDay && (arguments.has("end") ? endIsDay : !arguments.has("duration_minutes")) ? true : nil)
        let wholeDay = allDay ?? current?.isAllDay ?? false
        var start = startGiven
        var end = try arguments.date("end", endOfDay: wholeDay && endIsDay)
        if let minutes = try arguments.int("duration_minutes") {
            guard end == nil else { throw ToolError("Pass end or duration_minutes, not both") }
            let from = start ?? current?.start
            end = from.map { $0.addingTimeInterval(TimeInterval(min(max(minutes, 1), 86_400) * 60)) }
        }
        if wholeDay {
            start = start.map { calendar.startOfDay(for: $0) }
            if let day = end {
                end = calendar.startOfDay(for: day).addingTimeInterval(86_399)
            } else if let start, current == nil || (allDay == true && current?.isAllDay == false) {
                // A new all-day event, or a timed one turned all-day, lasts one day; an all-day one keeps its length.
                end = start.addingTimeInterval(86_399)
            }
        }
        return (start, end, allDay)
    }

    /// "Moves to Wed 22 Oct 10:00–11:00; title: Planning", for approvals and replies.
    static func describe(_ before: Event, _ after: Event) -> String {
        var parts: [String] = []
        if before.start != after.start || before.end != after.end || before.isAllDay != after.isAllDay {
            parts.append("moves to " + (Render.line(after).components(separatedBy: " · ").first ?? ""))
        }
        if before.title != after.title { parts.append("title: \(after.title)") }
        if before.location != after.location { parts.append(after.location.map { "location: \($0)" } ?? "no location") }
        if before.calendarID != after.calendarID { parts.append("to calendar \(after.calendarTitle)") }
        if before.notes != after.notes { parts.append("notes changed") }
        if before.url != after.url { parts.append("link changed") }
        if before.alarms != after.alarms { parts.append(after.alarms.isEmpty ? "no alarms" : "alarms changed") }
        if before.availability != after.availability { parts.append("shows as \(after.availability.rawValue)") }
        if before.recurrence != after.recurrence { parts.append(after.recurrence.map { "repeats \($0.summary)" } ?? "no longer repeats") }
        let text = parts.joined(separator: "; ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func span(_ arguments: Arguments) throws -> Span {
        guard let text = try arguments.string("span") else { return .thisEvent }
        guard let span = Span(rawValue: text.lowercased()) else { throw ToolError("span must be \"this\" or \"future\"") }
        return span
    }

    // MARK: create_event

    var createEvent: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "create_event", "Create event",
                """
                Add an event. A start without a time (YYYY-MM-DD) makes an all-day event; a timed event lasts \
                duration_minutes (default 60) unless end is given. Goes to the default calendar unless calendar is \
                given. EventKit cannot invite attendees: create it for the user, who can invite people in Calendar.
                """,
                Schema.object(Self.changeProperties, required: ["title", "start"]), kind: .change),
            kind: .change
        ) { arguments in
            try self.requireChanges()
            let title = try arguments.requiredString("title")
            let calendar = try self.targetCalendar(arguments)
            var (start, end, allDay) = try self.times(arguments, current: nil)
            guard let begin = start else { throw ToolError("start is required") }
            if end == nil { end = begin.addingTimeInterval(3600) }
            start = begin
            let draft = EventDraft(
                title: title, start: begin, end: end!, isAllDay: allDay ?? false, calendarID: calendar.id,
                timeZone: try arguments.string("time_zone"), location: try arguments.string("location"),
                notes: try arguments.string("notes"), url: try arguments.string("url"), availability: try self.availability(arguments),
                alarms: try self.alarms(arguments) ?? [], recurrence: try self.recurrence(arguments))
            guard draft.end >= draft.start else { throw ToolError("end must be after start") }
            if try arguments.bool("dry_run") == true {
                let preview = Event(
                    eventID: "(new)", calendarID: calendar.id, calendarTitle: calendar.title, title: draft.title, start: draft.start, end: draft.end,
                    isAllDay: draft.isAllDay, timeZone: draft.timeZone, location: draft.location, notes: draft.notes, url: draft.url,
                    availability: draft.availability ?? (draft.isAllDay ? .free : .busy), alarms: draft.alarms, recurrence: draft.recurrence)
                var detail = Render.detail(preview, notesLimit: 4000)
                if case .object(let pairs) = detail { detail = .object(pairs.filter { !["id", "link"].contains($0.0) }) }
                return ToolReply(json: .obj([("dry_run", .bool(true)), ("would_create", detail)]), summary: "dry run: 1 event")
            }
            let created = try self.backend.create(draft)
            let record = ChangeRecord(tool: "create_event", kind: .created, before: nil, after: created)
            self.record([record])
            return ToolReply(
                json: .obj([("created", Render.detail(created, notesLimit: 4000)), ("undo_id", self.journal == nil ? nil : .string(record.id.uuidString))]),
                summary: "created 1 event", event: created)
        }
    }

    // MARK: update_event

    var updateEvent: ToolDefinition {
        var properties = Self.changeProperties
        properties["id"] = Schema.string("The event id; for one occurrence of a repeating event, its occurrence id")
        properties["span"] = Schema.string("For a repeating event: this occurrence only (default) or it and all later ones", enum: ["this", "future"])
        properties["remove_repeat"] = Schema.boolean("Stop the event repeating (with span future)")
        return ToolDefinition(
            tool: Self.tool(
                "update_event", "Update event",
                """
                Change or move an event: only the fields given change, and a new start keeps the length unless end or \
                duration_minutes is given. For a repeating event, span "this" changes one occurrence and "future" it \
                and every later one. Changing an event other people are invited to may notify them and asks the user first.
                """,
                Schema.object(properties, required: ["id"]), kind: .change, idempotent: true),
            kind: .change
        ) { arguments in
            try self.requireChanges()
            let ref = try arguments.ref("id")
            let span = try Self.span(arguments)
            let current = try self.event(ref)
            let (start, end, allDay) = try self.times(arguments, current: current)
            var change = EventChange(
                title: try arguments.string("title"), start: start, end: end, isAllDay: allDay, timeZone: try arguments.string("time_zone"),
                location: try arguments.clearableString("location"), notes: try arguments.clearableString("notes"),
                url: try arguments.clearableString("url"), availability: try self.availability(arguments), alarms: try self.alarms(arguments),
                recurrence: try self.recurrence(arguments), removeRecurrence: try arguments.bool("remove_repeat") ?? false)
            if arguments.has("calendar") {
                let target = try self.targetCalendar(arguments)
                if target.id != current.calendarID { change.calendarID = target.id }
            }
            guard !change.isEmpty else { throw ToolError("Nothing to change: pass at least one field (title, start, end, location, …)") }
            if (change.recurrence != nil || change.removeRecurrence) && span == .thisEvent && current.isRecurring {
                throw ToolError("A repeat rule changes the series: pass span \"future\".")
            }
            var preview = change.applied(to: current)
            if let id = change.calendarID, let target = try? self.resolveCalendar(id) { preview.calendarTitle = target.title }
            let description = Self.describe(current, preview)
            if try arguments.bool("dry_run") == true {
                return ToolReply(
                    json: .obj([
                        ("dry_run", .bool(true)), ("event", Render.event(current)), ("would_change", .string(description)),
                        ("after", Render.event(preview)), ("asks_first", current.hasOtherAttendees && self.settings.current.sharedEventPolicy == .confirm ? .bool(true) : nil),
                    ]),
                    summary: "dry run: 1 event", event: current)
            }
            try await self.authorize(tool: "update_event", deleting: false, events: current.hasOtherAttendees ? [current] : [], detail: description)
            let updated = try self.backend.update(ref, change, span: span)
            let record = ChangeRecord(tool: "update_event", kind: .updated, span: span, before: current, after: updated)
            self.record([record])
            return ToolReply(
                json: .obj([
                    ("updated", Render.detail(updated, notesLimit: 4000)), ("changed", .string(description)),
                    ("span", current.isRecurring ? .string(span.rawValue) : nil),
                    ("undo_id", self.journal == nil ? nil : .string(record.id.uuidString)),
                ]),
                summary: "updated 1 event", event: updated)
        }
    }

    // MARK: delete_event

    var deleteEvent: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "delete_event", "Delete events",
                """
                Delete events (Calendar has no Trash). By default the user approves each deletion in the menu bar app; \
                undo_change brings an event back, without its attendees. For a repeating event, span "this" deletes one \
                occurrence and "future" it and every later one. Use dry_run to preview.
                """,
                Schema.object([
                    "ids": Schema.ids("Event ids (occurrence ids for single occurrences)"),
                    "span": Schema.string("For repeating events: this occurrence only (default) or it and all later ones", enum: ["this", "future"]),
                    "dry_run": Schema.boolean("List what would be deleted without deleting"),
                ], required: ["ids"]), kind: .change, destructive: true),
            kind: .change
        ) { arguments in
            try self.requireChanges()
            var refs = try arguments.refs("ids")
            if refs.isEmpty, arguments.has("id") { refs = try arguments.refs("id") }
            guard !refs.isEmpty else { throw ToolError("ids is required") }
            try self.checkBatch(refs.count)
            let span = try Self.span(arguments)
            let events = try refs.map(self.event)
            let calendars = try self.backend.calendars()
            if let locked = events.first(where: { event in calendars.first { $0.id == event.calendarID }?.writable == false }) {
                throw ToolError("\"\(locked.title)\" is in a read-only calendar (\(locked.calendarTitle)). Nothing was deleted.")
            }
            if try arguments.bool("dry_run") == true {
                return ToolReply(
                    json: .obj([
                        ("dry_run", .bool(true)), ("would_delete", .array(events.map(Render.event))),
                        ("asks_first", self.settings.current.deletePolicy == .confirm ? .bool(true) : nil),
                    ]),
                    summary: "dry run: \(Self.plural(events.count, "event"))")
            }
            try await self.authorize(tool: "delete_event", deleting: true, events: events, detail: span == .futureEvents ? "Repeating events: this and every later occurrence." : nil)
            var deleted: [Event] = []
            var records: [ChangeRecord] = []
            var failures: [JSON] = []
            for (ref, event) in zip(refs, events) {
                try Task.checkCancellation()
                do {
                    try self.backend.delete(ref, span: span)
                    deleted.append(event)
                    records.append(ChangeRecord(tool: "delete_event", kind: .deleted, span: span, before: event, after: nil))
                } catch {
                    failures.append(.obj([("id", .string(ref.string)), ("error", .string(String(describing: error)))]))
                }
            }
            self.record(records)
            return ToolReply(
                json: .obj([
                    ("deleted", .array(deleted.map(Render.event))),
                    ("failed", failures.isEmpty ? nil : .array(failures)),
                    ("undo_ids", records.isEmpty || self.journal == nil ? nil : .array(records.map { .string($0.id.uuidString) })),
                ]),
                summary: "deleted \(Self.plural(deleted.count, "event"))\(failures.isEmpty ? "" : ", \(failures.count) failed")")
        }
    }
}
