import CalendarStore
import Foundation
import MCP

extension CalendarToolbox {
    var readTools: [ToolDefinition] {
        [listCalendars, listEvents, searchEvents, getEvent, agenda, findFreeTime, findConflicts, pendingInvitations, statistics]
    }

    static let calendarsProperty = Schema.strings("Calendars by id, title, or Account/Title (default: all, except those hidden in settings)")
    static let zoneProperty = Schema.string("Time zone for dates without an offset, e.g. Europe/Paris (default: the Mac's)")

    /// `start`/`end` arguments with defaults: `start` (or `defaultStart`), and `end` as the end of the `end` day, or
    /// `defaultLength` after the start.
    func period(_ arguments: Arguments, defaultStart: Date, defaultLength: TimeInterval) throws -> (Date, Date) {
        let start = try arguments.date("start") ?? defaultStart
        let end = try arguments.date("end", endOfDay: arguments.isDay("end")) ?? start.addingTimeInterval(defaultLength)
        guard end > start else { throw ToolError("end must be after start") }
        return (start, end)
    }

    var startOfToday: Date { Calendar.current.startOfDay(for: now()) }

    // MARK: list_calendars

    var listCalendars: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "list_calendars", "List calendars",
                "Calendars with their account, colour, whether they can be changed, and which one new events go to by default.",
                Schema.object([:]), kind: .read),
            kind: .read
        ) { _ in
            let all = try self.backend.calendars()
            let hidden = Set(self.settings.current.hiddenCalendars)
            let visible = all.filter { !hidden.contains($0.id) }
            return ToolReply(
                json: .obj([
                    ("calendars", .array(visible.map(Render.calendar))),
                    ("hidden", hidden.isEmpty ? nil : .int(Int64(all.count - visible.count))),
                ]),
                summary: Self.plural(visible.count, "calendar"))
        }
    }

    // MARK: list_events

    var listEvents: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "list_events", "List events",
                "Events in a period, from all calendars or some, repeating events expanded to their occurrences, in order. Default: the next 7 days from the start of today.",
                Schema.object([
                    "start": Schema.string("Start of the period: \(Schema.date) (default: today)"),
                    "end": Schema.string("End of the period; a day means through that day (default: 7 days after start)"),
                    "calendars": Self.calendarsProperty,
                    "include_declined": Schema.boolean("Include invitations you declined and cancelled events (default false)"),
                    "limit": Schema.integer("Most events to return (default 200)", minimum: 1, maximum: 1000),
                    "time_zone": Self.zoneProperty,
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let (start, end) = try self.period(arguments, defaultStart: self.startOfToday, defaultLength: 7 * 86_400)
            var events = try self.events(from: start, to: end, calendarIDs: self.calendarIDs(arguments))
            if try arguments.bool("include_declined") != true {
                events.removeAll { $0.myStatus == .declined || $0.status == .cancelled }
            }
            let limit = try arguments.int("limit", default: 200, in: 1...1000)
            return ToolReply(
                json: .obj([
                    ("start", Render.date(start)), ("end", Render.date(end)), ("count", .int(Int64(events.count))),
                    ("events", .array(events.prefix(limit).map(Render.event))),
                    ("truncated", events.count > limit ? .bool(true) : nil),
                ]),
                summary: Self.plural(events.count, "event"))
        }
    }

    // MARK: search_events

    var searchEvents: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "search_events", "Search events",
                """
                Find events by words (title, place, notes, people), by person, place or calendar, video calls, your answer, \
                repeating or all-day, within dates (default: one year back to one year ahead). Every word of query must \
                match; matching ignores case and accents. With group_by, returns counts and hours per calendar, month, \
                weekday or person instead of events.
                """,
                Schema.object([
                    "query": Schema.string("Words to find in the title, location, notes or attendees"),
                    "title": Schema.string("Words to find in the title only"),
                    "person": Schema.string("A name or address among the attendees or the organizer"),
                    "location": Schema.string("Words to find in the location"),
                    "calendars": Self.calendarsProperty,
                    "start": Schema.string("From: \(Schema.date) (default: a year ago)"),
                    "end": Schema.string("Until (default: a year from now)"),
                    "has_video": Schema.boolean("Only events with (true) or without (false) a video call link"),
                    "my_status": Schema.string("Your answer to the invitation", enum: ["pending", "accepted", "declined", "tentative"]),
                    "recurring": Schema.boolean("Only repeating (true) or one-off (false) events"),
                    "all_day": Schema.boolean("Only all-day (true) or timed (false) events"),
                    "group_by": Schema.string("Return counts and hours per group instead of events", enum: ["calendar", "month", "weekday", "person"]),
                    "order": Schema.string("By start: oldest first (asc, default) or newest first (desc)", enum: ["asc", "desc"]),
                    "limit": Schema.integer("Most events to return (default 50)", minimum: 1, maximum: 500),
                    "offset": Schema.integer("Skip this many matches (paging)", minimum: 0),
                    "time_zone": Self.zoneProperty,
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let year: TimeInterval = 366 * 86_400
            let start = try arguments.date("start") ?? self.startOfToday.addingTimeInterval(-year)
            let end = try arguments.date("end", endOfDay: arguments.isDay("end")) ?? self.startOfToday.addingTimeInterval(year)
            var events = try self.events(from: start, to: end, calendarIDs: self.calendarIDs(arguments))
            if let query = try arguments.string("query") { events = events.filter { EventText.matches($0, query) } }
            if let title = try arguments.string("title") { events = events.filter { EventText.matches($0, title, fields: [.title]) } }
            if let location = try arguments.string("location") { events = events.filter { EventText.matches($0, location, fields: [.location]) } }
            if let person = try arguments.string("person") { events = events.filter { EventText.involves($0, person) } }
            if let video = try arguments.bool("has_video") { events = events.filter { (VideoLink.find(in: $0) != nil) == video } }
            if let status = try arguments.string("my_status") {
                guard let wanted = Participant.Status(rawValue: status) else { throw ToolError("my_status must be pending, accepted, declined or tentative") }
                events = events.filter { $0.myStatus == wanted }
            }
            if let recurring = try arguments.bool("recurring") { events = events.filter { $0.isRecurring == recurring } }
            if let allDay = try arguments.bool("all_day") { events = events.filter { $0.isAllDay == allDay } }
            if try arguments.string("order") == "desc" { events.reverse() }
            if let group = try arguments.string("group_by") {
                return ToolReply(json: try Self.grouped(events, by: group), summary: "\(Self.plural(events.count, "event")) by \(group)")
            }
            let limit = try arguments.int("limit", default: 50, in: 1...500)
            let offset = try arguments.int("offset", default: 0, in: 0...Int.max)
            let page = events.dropFirst(offset).prefix(limit)
            return ToolReply(
                json: .obj([
                    ("total", .int(Int64(events.count))),
                    ("events", .array(page.map(Render.event))),
                    ("next_offset", offset + page.count < events.count ? .int(Int64(offset + page.count)) : nil),
                ]),
                summary: events.count == 1 ? "1 match" : "\(events.count) matches")
        }
    }

    static func grouped(_ events: [Event], by group: String) throws -> JSON {
        let calendar = Calendar.current
        let key: (Event) -> [String]
        switch group {
        case "calendar": key = { [$0.calendarTitle] }
        case "month": key = { [String(DayFormat.string($0.start).prefix(7))] }
        case "weekday": key = { [calendar.weekdaySymbols[calendar.component(.weekday, from: $0.start) - 1]] }
        case "person": key = { event in event.attendees.filter { !$0.isCurrentUser && $0.kind == .person }.map { $0.name ?? $0.email ?? "?" } }
        default: throw ToolError("group_by must be calendar, month, weekday or person")
        }
        var table: [String: (count: Int, hours: Double)] = [:]
        for event in events {
            for name in key(event) {
                table[name, default: (0, 0)].count += 1
                if !event.isAllDay { table[name]!.hours += event.duration / 3600 }
            }
        }
        let rows = table.sorted { group == "month" ? $0.key < $1.key : ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        return .obj([
            ("total", .int(Int64(events.count))),
            ("groups", .array(rows.map { .obj([("name", .string($0.key)), ("events", .int(Int64($0.value.count))), ("hours", Render.hours($0.value.hours))]) })),
        ])
    }

    // MARK: get_event

    var getEvent: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "get_event", "Get event",
                "One event in full: notes, URL, organizer, attendees and their answers, alarms, repeat rule, video link, and its Calendar link.",
                Schema.object([
                    "id": Schema.string("The event id (an occurrence id for one occurrence of a repeating event)"),
                    "notes_limit": Schema.integer("Longest notes to return, in characters (default 4000)", minimum: 0, maximum: 100_000),
                ], required: ["id"]), kind: .read),
            kind: .read
        ) { arguments in
            let event = try self.event(arguments.ref("id"))
            let limit = try arguments.int("notes_limit", default: 4000, in: 0...100_000)
            return ToolReply(json: Render.detail(event, notesLimit: limit), summary: "1 event", event: event)
        }
    }

    // MARK: agenda

    var agenda: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "agenda", "Agenda",
                """
                A day (or a few) in one call: the events in order, what is on now and next, conflicts, the free time left \
                within working hours, invitations still waiting for your answer, and totals. Start here for "what's my day".
                """,
                Schema.object([
                    "date": Schema.string("The first day, YYYY-MM-DD or today/tomorrow (default: today)"),
                    "days": Schema.integer("How many days (default 1)", minimum: 1, maximum: 14),
                    "time_zone": Self.zoneProperty,
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let calendar = arguments.calendar
            let first = calendar.startOfDay(for: try arguments.date("date") ?? self.now())
            let days = try arguments.int("days", default: 1, in: 1...14)
            let end = calendar.date(byAdding: .day, value: days, to: first)!
            let now = self.now()
            let all = try self.events(from: first, to: end, calendarIDs: self.calendarIDs(arguments))
            let events = all.filter { $0.status != .cancelled && $0.myStatus != .declined }
            let timed = events.filter { !$0.isAllDay }
            let current = timed.filter { $0.start <= now && $0.end > now && Busy.blocks($0) }
            let next = timed.first { $0.start > now }
            let settings = self.settings.current
            let free = FreeTime.slots(
                events: events, from: max(first, now), to: end, duration: 15 * 60, hours: settings.workHours, calendar: calendar)
            let conflicts = Conflicts.find(events)
            let pending = all.filter { $0.myStatus == .pending }
            let meetings = timed.filter(\.hasOtherAttendees)
            return ToolReply(
                json: .obj([
                    ("from", Render.day(first)), ("days", days > 1 ? .int(Int64(days)) : nil),
                    ("summary", .obj([
                        ("events", .int(Int64(timed.count))),
                        ("all_day", events.count > timed.count ? .int(Int64(events.count - timed.count)) : nil),
                        ("meeting_hours", Render.hours(meetings.reduce(0) { $0 + $1.duration } / 3600)),
                        ("busy_hours", Render.hours(Busy.intervals(timed).reduce(0) { $0 + $1.duration } / 3600)),
                        ("first_start", timed.first.map { Render.date($0.start) }),
                        ("last_end", timed.map(\.end).max().map(Render.date)),
                        ("free_minutes_left", .int(Int64(free.reduce(0) { $0 + $1.duration } / 60))),
                    ])),
                    ("now", current.isEmpty ? nil : .array(current.map(Render.event))),
                    ("next", next.map(Render.event)),
                    ("all_day_events", events.count > timed.count ? .array(events.filter(\.isAllDay).map(Render.event)) : nil),
                    ("events", .array(timed.map(Render.event))),
                    ("conflicts", conflicts.isEmpty ? nil : .array(conflicts.map(Self.conflict))),
                    ("free", .array(free.map(Render.slot))),
                    ("pending_invitations", pending.isEmpty ? nil : .array(pending.map(Render.event))),
                ]),
                summary: "\(Self.plural(timed.count, "event")), \(conflicts.isEmpty ? "no" : String(conflicts.count)) conflict\(conflicts.count == 1 ? "" : "s")")
        }
    }

    static func conflict(_ pair: (Event, Event)) -> JSON {
        let overlap = min(pair.0.end, pair.1.end).timeIntervalSince(max(pair.0.start, pair.1.start))
        return .obj([
            ("first", .obj([("id", .string(pair.0.id)), ("title", .string(pair.0.title)), ("start", Render.date(pair.0.start)), ("end", Render.date(pair.0.end))])),
            ("second", .obj([("id", .string(pair.1.id)), ("title", .string(pair.1.title)), ("start", Render.date(pair.1.start)), ("end", Render.date(pair.1.end))])),
            ("overlap_minutes", .int(Int64(overlap / 60))),
        ])
    }

    // MARK: find_free_time

    var findFreeTime: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "find_free_time", "Find free time",
                """
                Free slots of at least duration_minutes between busy events, within working hours by default (Settings), \
                with an optional buffer around events. Free, declined and cancelled events, and all-day events not marked \
                busy, do not block time. Each slot is reported whole: any start inside it works.
                """,
                Schema.object([
                    "start": Schema.string("From: \(Schema.date) (default: now)"),
                    "end": Schema.string("Until (default: 7 days after start)"),
                    "duration_minutes": Schema.integer("Shortest useful slot (default 30)", minimum: 5, maximum: 1440),
                    "work_hours_only": Schema.boolean("Only within working hours and working days (default true)"),
                    "earliest": Schema.string("No slot before this time of day, HH:MM"),
                    "latest": Schema.string("No slot after this time of day, HH:MM"),
                    "weekdays": Schema.strings("Only these days: mon, tue, … or 1 (Sunday) to 7"),
                    "buffer_minutes": Schema.integer("Keep this much time free before and after events (default 0)", minimum: 0, maximum: 240),
                    "calendars": Schema.strings("Calendars whose events count as busy (default: all visible)"),
                    "limit": Schema.integer("Most slots to return (default 20)", minimum: 1, maximum: 200),
                    "time_zone": Self.zoneProperty,
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let (start, end) = try self.period(arguments, defaultStart: self.now(), defaultLength: 7 * 86_400)
            let duration = TimeInterval(try arguments.int("duration_minutes", default: 30, in: 5...1440) * 60)
            let settings = self.settings.current
            var hours: WorkHours? = try arguments.bool("work_hours_only") == false ? nil : settings.workHours
            let earliest = try arguments.timeOfDay("earliest")
            let latest = try arguments.timeOfDay("latest")
            let days = try arguments.weekdays("weekdays")
            if earliest != nil || latest != nil || days != nil {
                var shaped = hours ?? WorkHours(start: 0, end: 24 * 60, weekdays: Set(1...7))
                if let earliest { shaped.start = max(hours == nil ? 0 : shaped.start, earliest) }
                if let latest { shaped.end = min(shaped.end, latest) }
                if let days { shaped.weekdays = Set(days) }
                hours = shaped
            }
            let events = try self.events(from: start.addingTimeInterval(-86_400), to: end.addingTimeInterval(86_400), calendarIDs: self.calendarIDs(arguments))
            let buffer = TimeInterval(try arguments.int("buffer_minutes", default: 0, in: 0...240) * 60)
            let slots = FreeTime.slots(events: events, from: start, to: end, duration: duration, hours: hours, buffer: buffer, calendar: arguments.calendar)
            let limit = try arguments.int("limit", default: 20, in: 1...200)
            let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return ToolReply(
                json: .obj([
                    ("slots", .array(slots.prefix(limit).map(Render.slot))),
                    ("more", slots.count > limit ? .int(Int64(slots.count - limit)) : nil),
                    ("hours", hours.map { .string("\(WorkHours.text($0.start))–\(WorkHours.text($0.end)) \($0.weekdays.sorted().map { names[$0] }.joined(separator: " "))") }),
                ]),
                summary: Self.plural(slots.count, "slot"))
        }
    }

    // MARK: find_conflicts

    var findConflicts: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "find_conflicts", "Find conflicts",
                "Pairs of timed events that overlap and both take the time (free, declined and cancelled events do not count). Default: the next 14 days.",
                Schema.object([
                    "start": Schema.string("From: \(Schema.date) (default: today)"),
                    "end": Schema.string("Until (default: 14 days after start)"),
                    "calendars": Self.calendarsProperty,
                    "time_zone": Self.zoneProperty,
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let (start, end) = try self.period(arguments, defaultStart: self.startOfToday, defaultLength: 14 * 86_400)
            let pairs = Conflicts.find(try self.events(from: start, to: end, calendarIDs: self.calendarIDs(arguments)))
            return ToolReply(json: .obj([("conflicts", .array(pairs.map(Self.conflict)))]), summary: Self.plural(pairs.count, "conflict"))
        }
    }

    // MARK: pending_invitations

    var pendingInvitations: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "pending_invitations", "Pending invitations",
                "Invitations from other people you have not answered yet (default: from now to 60 days ahead). Answer them in Calendar: EventKit cannot.",
                Schema.object([
                    "start": Schema.string("From: \(Schema.date) (default: now)"),
                    "end": Schema.string("Until (default: 60 days after start)"),
                    "time_zone": Self.zoneProperty,
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let (start, end) = try self.period(arguments, defaultStart: self.now(), defaultLength: 60 * 86_400)
            let pending = try self.events(from: start, to: end, calendarIDs: self.calendarIDs(arguments)).filter { $0.myStatus == .pending && $0.status != .cancelled }
            return ToolReply(json: .obj([("invitations", .array(pending.map(Render.event)))]), summary: Self.plural(pending.count, "invitation"))
        }
    }

    // MARK: calendar_statistics

    var statistics: ToolDefinition {
        ToolDefinition(
            tool: Self.tool(
                "calendar_statistics", "Calendar statistics",
                """
                Where time went in a period (default: the last 4 weeks): event and meeting hours, all-day events, the share \
                of repeating events, back-to-back meetings, hours per calendar, weekday, hour of the day and person, the \
                busiest days and the longest events. Declined and cancelled events are left out.
                """,
                Schema.object([
                    "start": Schema.string("From: \(Schema.date) (default: 28 days ago)"),
                    "end": Schema.string("Until (default: the end of today)"),
                    "calendars": Self.calendarsProperty,
                    "time_zone": Self.zoneProperty,
                ]), kind: .read),
            kind: .read
        ) { arguments in
            let start = try arguments.date("start") ?? self.startOfToday.addingTimeInterval(-28 * 86_400)
            let end = try arguments.date("end", endOfDay: arguments.isDay("end")) ?? self.startOfToday.addingTimeInterval(86_399)
            let events = try self.events(from: start, to: end, calendarIDs: self.calendarIDs(arguments))
            let stats = TimeStatistics(events: events, calendar: arguments.calendar)
            func buckets(_ list: [TimeStatistics.Bucket]) -> JSON {
                .array(list.map { .obj([("name", .string($0.name)), ("hours", Render.hours($0.hours)), ("events", .int(Int64($0.events)))]) })
            }
            let weeks = max(end.timeIntervalSince(start) / (7 * 86_400), 1 / 7)
            return ToolReply(
                json: .obj([
                    ("start", Render.date(start)), ("end", Render.date(end)),
                    ("events", .int(Int64(stats.events))), ("hours", Render.hours(stats.timedHours)),
                    ("meetings", .int(Int64(stats.meetings))), ("meeting_hours", Render.hours(stats.meetingHours)),
                    ("meeting_hours_per_week", Render.hours(stats.meetingHours / weeks)),
                    ("all_day", .int(Int64(stats.allDay))),
                    ("repeating_share", .double((stats.recurringShare * 100).rounded() / 100)),
                    ("back_to_back", .int(Int64(stats.backToBack))),
                    ("by_calendar", buckets(stats.byCalendar)), ("by_weekday", buckets(stats.byWeekday)),
                    ("by_hour", buckets(stats.byHour)), ("by_person", buckets(stats.byPerson)),
                    ("busiest_days", buckets(stats.busiestDays)),
                    ("longest", .array(stats.longest.map(Render.event))),
                ]),
                summary: "\(Self.plural(stats.events, "event")), \(Int(stats.meetingHours.rounded())) h of meetings")
        }
    }
}
