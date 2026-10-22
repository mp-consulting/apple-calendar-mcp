import CalendarStore
import Foundation
import MCP

extension CalendarToolbox {
    var fileTools: [ToolDefinition] { [importICS, exportEvents, openInCalendar] }

    var pathGuard: PathGuard {
        let folders = settings.current.fileDirectories
        return PathGuard(writeAllowlist: folders, readAllowlist: folders)
    }

    // MARK: import_ics

    var importICS: ToolDefinition {
        ToolDefinition(
            "import_ics", "Import .ics file",
            """
            Add the events of an iCalendar file (an invitation saved from Mail, a booking, an export) to a calendar. \
            Events already in the calendar (same UID) are skipped. Importing an invitation adds a copy; it does not \
            answer the organizer. Use dry_run to see the events first.
            """,
            Schema.object([
                "path": Schema.string("The .ics file"),
                "calendar": Schema.string("Calendar by id, title, or Account/Title (default: the default calendar)"),
                "dry_run": Schema.boolean("List the file's events without adding them"),
            ], required: ["path"]), kind: .change
        ) { arguments in
            let path = try self.pathGuard.checkRead(arguments.requiredString("path"))
            guard ["ics", "ical", "icalendar", "ifb"].contains((path as NSString).pathExtension.lowercased()) else {
                throw ToolError("Only .ics files can be imported: \(path)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            guard size <= 5_000_000 else { throw ToolError("The file is larger than 5 MB.") }
            guard let data = FileManager.default.contents(atPath: path) else { throw ToolError("Could not read \(path)") }
            let text = String(decoding: data, as: UTF8.self)
            let items = try ICS.parse(text, calendar: arguments.calendar)
            guard !items.isEmpty else { throw ToolError("The file holds no events.") }
            try self.checkBatch(items.count)
            let calendar = try self.targetCalendar(arguments)
            func preview(_ item: ICS.Item) -> JSON {
                let event = Event(
                    eventID: item.uid ?? "(new)", calendarID: calendar.id, calendarTitle: calendar.title, title: item.draft.title,
                    start: item.draft.start, end: item.draft.end, isAllDay: item.draft.isAllDay, location: item.draft.location,
                    recurrence: item.draft.recurrence)
                guard case .object(var pairs) = Render.event(event) else { return Render.event(event) }
                pairs.removeAll { $0.0 == "id" }
                if let organizer = item.organizer { pairs.append(("organizer", .string(organizer))) }
                if !item.attendees.isEmpty { pairs.append(("attendees", .int(Int64(item.attendees.count)))) }
                if let repeatRule = item.draft.recurrence { pairs.append(("repeat", .string(repeatRule.summary))) }
                return .object(pairs)
            }
            if try arguments.bool("dry_run") == true {
                    return ToolReply(
                    json: .obj([
                        ("dry_run", .bool(true)), ("calendar", .string(calendar.title)),
                        ("invitation", items.contains(where: \.isInvitation) ? .bool(true) : nil),
                        ("events", .array(items.map(preview))),
                    ]),
                    summary: "dry run: \(plural(items.count, "event"))")
            }
            var created: [Event] = []
            var skipped: [JSON] = []
            var records: [ChangeRecord] = []
            // UIDs already in any calendar, from one query around all the items.
            let dated = items.filter { $0.uid != nil }
            let known: Set<String> = dated.isEmpty ? [] : Set(try self.backend.events(
                in: dated.map(\.draft.start).min()!.addingTimeInterval(-86_400), dated.map(\.draft.end).max()!.addingTimeInterval(86_400)
            ).compactMap(\.externalID))
            for item in items {
                try Task.checkCancellation()
                if let uid = item.uid {
                    if known.contains(uid) {
                        skipped.append(.obj([("title", .string(item.draft.title)), ("reason", .string("already in the calendar"))]))
                        continue
                    }
                }
                var draft = item.draft
                draft.calendarID = calendar.id
                let event = try self.backend.create(draft)
                created.append(event)
                records.append(ChangeRecord(tool: "import_ics", kind: .created, before: nil, after: event))
            }
            self.record(records)
            return ToolReply(
                json: .obj([
                    ("created", .array(created.map(Render.event))), ("skipped", skipped.isEmpty ? nil : .array(skipped)),
                    ("note", items.contains(where: \.isInvitation) ? .string("This was an invitation: the organizer was not answered. Answer it in Calendar or Mail.") : nil),
                    ("undo_ids", self.undoIDs(records)),
                ]),
                summary: "imported \(plural(created.count, "event"))", event: created.first)
        }
    }

    // MARK: export_events

    var exportEvents: ToolDefinition {
        ToolDefinition(
            "export_events", "Export events",
            """
            Write the events of a period (default: today and the next 30 days) to one file: .ics for other calendar \
            apps, CSV for a spreadsheet, or JSON. Returns the path and the number of events, not their content.
            """,
            Schema.object([
                "path": Schema.string("The file to write (.ics, .csv or .json)"),
                "format": Schema.string("Default: from the file's extension", enum: ["ics", "csv", "json"]),
                "start": Schema.string("From: \(Schema.date) (default: today)"),
                "end": Schema.string("Until (default: 30 days after start)"),
                "calendars": Self.calendarsProperty,
                "query": Schema.string("Only events matching these words (title, place, notes, people)"),
                "time_zone": Self.zoneProperty,
            ], required: ["path"]), kind: .fileWrite
        ) { arguments in
            let path = try self.pathGuard.checkWrite(arguments.requiredString("path"))
            let format = try arguments.string("format")?.lowercased() ?? (path as NSString).pathExtension.lowercased()
            guard ["ics", "csv", "json"].contains(format) else { throw ToolError("format must be ics, csv or json (or a path ending in one)") }
            let (start, end) = try self.period(arguments, defaultStart: self.startOfToday, defaultLength: 31 * 86_400 - 1)
            var events = try self.events(from: start, to: end, calendarIDs: self.calendarIDs(arguments))
            if let query = try arguments.string("query") { events = events.filter { EventText.matches($0, query) } }
            let text: String
            switch format {
            case "ics": text = ICS.write(Self.seriesOnce(events), calendar: arguments.calendar)
            case "csv": text = Self.csv(events)
            default: text = JSON.array(events.map { Render.detail($0, notesLimit: 100_000) }).serialized(pretty: true) + "\n"
            }
            let url = URL(filePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return ToolReply(
                json: .obj([("path", .string(path)), ("format", .string(format)), ("events", .int(Int64(events.count)))]),
                summary: "exported \(plural(events.count, "event")) to \(format)")
        }
    }

    /// A repeating event once (its first occurrence in the period, which carries the rule) for iCalendar.
    static func seriesOnce(_ events: [Event]) -> [Event] {
        var seen = Set<String>()
        return events.filter { !$0.isRecurring || $0.isDetached || seen.insert($0.eventID).inserted }
    }

    static func csv(_ events: [Event]) -> String {
        func field(_ text: String) -> String {
            let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            // A leading = + - @ would run as a formula in a spreadsheet.
            let safe = flat.first.map { "=+-@".contains($0) } == true ? "'" + flat : flat
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["start,end,all_day,title,calendar,location,attendees,video,repeat,notes"]
        for event in events {
            let attendees = event.attendees.filter { !$0.isCurrentUser }.map(\.formatted).joined(separator: "; ")
            lines.append([
                Render.isoDate(event.start), Render.isoDate(event.end), event.isAllDay ? "yes" : "", event.title, event.calendarTitle,
                event.location ?? "", attendees, VideoLink.find(in: event) ?? "", event.recurrence?.summary ?? "",
                Render.truncate(event.notes ?? "", 500),
            ].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: open_in_calendar

    var openInCalendar: ToolDefinition {
        ToolDefinition(
            "open_in_calendar", "Open in Calendar",
            "Show an event in the Calendar app (to invite people, answer an invitation, or look at it), or open Calendar.",
            Schema.object(["id": Schema.string("The event to show (default: just open Calendar)")]), kind: .fileWrite
        ) { arguments in
            if arguments.has("id") {
                let event = try self.event(arguments.ref("id"))
                guard let url = URL(string: event.calendarLink), self.open(url) else { throw ToolError("Calendar could not be opened.") }
                return ToolReply(json: .obj([("opened", .string(event.title))]), summary: "opened 1 event", event: event)
            }
            guard self.open(URL(filePath: "/System/Applications/Calendar.app")) else { throw ToolError("Calendar could not be opened.") }
            return ToolReply(json: .obj([("opened", .string("Calendar"))]), summary: "opened Calendar")
        }
    }
}
