import Foundation

/// iCalendar (RFC 5545) files: reads the events of an invitation or export, writes events for other apps.
public enum ICS {
    /// One VEVENT, as far as EventKit can take it (attendees are read for display only).
    public struct Item: Sendable, Equatable {
        public var uid: String?
        public var draft: EventDraft
        public var organizer: String?
        public var attendees: [String]
        /// METHOD:REQUEST: an invitation (importing it adds a copy, it does not answer the organizer).
        public var isInvitation: Bool
    }

    // MARK: Reading

    public static func parse(_ text: String, calendar: Calendar = .current) throws -> [Item] {
        let lines = unfold(text)
        guard lines.contains(where: { $0.uppercased().hasPrefix("BEGIN:VCALENDAR") || $0.uppercased().hasPrefix("BEGIN:VEVENT") }) else {
            throw CalendarError("Not an iCalendar file (no BEGIN:VCALENDAR).")
        }
        let method = lines.first { $0.uppercased().hasPrefix("METHOD:") }.map { String($0.dropFirst(7)).uppercased() }
        var items: [Item] = []
        var properties: [(name: String, parameters: [String: String], value: String)]?
        var inAlarm = false
        var alarmTriggers: [String] = []
        for line in lines {
            let upper = line.uppercased()
            if upper == "BEGIN:VEVENT" {
                properties = []
                alarmTriggers = []
                continue
            }
            if upper == "BEGIN:VALARM" { inAlarm = true; continue }
            if upper == "END:VALARM" { inAlarm = false; continue }
            if upper == "END:VEVENT", let current = properties {
                if let item = makeItem(current, alarms: alarmTriggers, invitation: method == "REQUEST", calendar: calendar) { items.append(item) }
                properties = nil
                continue
            }
            guard properties != nil, let property = split(line) else { continue }
            if inAlarm {
                if property.name == "TRIGGER" { alarmTriggers.append(property.value) }
            } else {
                properties!.append(property)
            }
        }
        return items
    }

    static func makeItem(
        _ properties: [(name: String, parameters: [String: String], value: String)], alarms: [String], invitation: Bool, calendar: Calendar
    ) -> Item? {
        func first(_ name: String) -> (parameters: [String: String], value: String)? {
            properties.first { $0.name == name }.map { ($0.parameters, $0.value) }
        }
        guard let startProperty = first("DTSTART"), let (start, allDay) = date(startProperty.value, startProperty.parameters, calendar: calendar)
        else { return nil }
        var end: Date
        if let endProperty = first("DTEND"), let (parsed, _) = date(endProperty.value, endProperty.parameters, calendar: calendar) {
            end = parsed
        } else if let duration = first("DURATION").flatMap({ seconds($0.value) }) {
            end = start.addingTimeInterval(duration)
        } else {
            end = allDay ? calendar.date(byAdding: .day, value: 1, to: start) ?? start : start
        }
        // iCalendar ends all-day events at the next midnight; EventKit at the last second of the last day.
        if allDay, end > start { end = end.addingTimeInterval(-1) }
        let transparent = first("TRANSP")?.value.uppercased() == "TRANSPARENT"
        let draft = EventDraft(
            title: first("SUMMARY").map { unescape($0.value) } ?? "(no title)", start: start, end: max(end, start), isAllDay: allDay,
            timeZone: allDay ? nil : first("DTSTART")?.parameters["TZID"], location: first("LOCATION").map { unescape($0.value) }.nilIfEmpty,
            notes: first("DESCRIPTION").map { unescape($0.value) }.nilIfEmpty, url: first("URL")?.value.nilIfEmpty,
            availability: transparent ? .free : nil, alarms: alarms.compactMap(seconds).map { Alarm(minutesBefore: Int((-$0 / 60).rounded())) },
            recurrence: first("RRULE").flatMap { rule($0.value, calendar: calendar) })
        let people = properties.filter { $0.name == "ATTENDEE" }.map { person($0.parameters, $0.value) }
        return Item(
            uid: first("UID")?.value, draft: draft, organizer: first("ORGANIZER").map { person($0.parameters, $0.value) }, attendees: people,
            isInvitation: invitation)
    }

    static func person(_ parameters: [String: String], _ value: String) -> String {
        let address = value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : value
        guard let name = parameters["CN"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }

    /// Lines with continuations joined (a line starting with a space or tab continues the previous one).
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// `NAME;PARAM=value;…:value`, the name and parameter names upper-cased.
    static func split(_ line: String) -> (name: String, parameters: [String: String], value: String)? {
        var inQuotes = false
        guard let colon = line.firstIndex(where: { character in
            if character == "\"" { inQuotes.toggle() }
            return character == ":" && !inQuotes
        }) else { return nil }
        let head = line[..<colon].split(separator: ";").map(String.init)
        guard let name = head.first?.uppercased() else { return nil }
        var parameters: [String: String] = [:]
        for parameter in head.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parameters[pair[0].uppercased()] = pair[1] }
        }
        return (name, parameters, String(line[line.index(after: colon)...]))
    }

    static func unescape(_ value: String) -> String {
        var out = ""
        var escaped = false
        for character in value {
            if escaped {
                out.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// A DATE or DATE-TIME (UTC with `Z`, in `TZID`, or floating in the local zone); true for a DATE (all day).
    static func date(_ value: String, _ parameters: [String: String], calendar: Calendar) -> (Date, Bool)? {
        let digits = value.filter { $0.isNumber }
        if parameters["VALUE"]?.uppercased() == "DATE" || (digits.count == 8 && !value.contains("T")) {
            guard digits.count >= 8, let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)),
                let day = Int(digits.dropFirst(6).prefix(2)),
                let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
            else { return nil }
            return (date, true)
        }
        guard digits.count >= 14, let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)),
            let day = Int(digits.dropFirst(6).prefix(2)), let hour = Int(digits.dropFirst(8).prefix(2)),
            let minute = Int(digits.dropFirst(10).prefix(2)), let second = Int(digits.dropFirst(12).prefix(2))
        else { return nil }
        var zoned = Calendar(identifier: .gregorian)
        if value.hasSuffix("Z") || value.hasSuffix("z") {
            zoned.timeZone = TimeZone(identifier: "UTC")!
        } else if let id = parameters["TZID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), let zone = TimeZone(identifier: id) ?? windowsZone(id) {
            zoned.timeZone = zone
        } else {
            zoned.timeZone = calendar.timeZone
        }
        guard let date = zoned.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else {
            return nil
        }
        return (date, false)
    }

    /// Outlook writes Windows zone names ("W. Europe Standard Time").
    static func windowsZone(_ name: String) -> TimeZone? {
        let table = [
            "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris", "GMT Standard Time": "Europe/London",
            "Central Europe Standard Time": "Europe/Budapest", "Eastern Standard Time": "America/New_York",
            "Central Standard Time": "America/Chicago", "Mountain Standard Time": "America/Denver",
            "Pacific Standard Time": "America/Los_Angeles", "UTC": "UTC", "Tokyo Standard Time": "Asia/Tokyo",
            "AUS Eastern Standard Time": "Australia/Sydney", "India Standard Time": "Asia/Kolkata", "China Standard Time": "Asia/Shanghai",
        ]
        return table[name].flatMap(TimeZone.init(identifier:))
    }

    /// `-PT15M`, `P1D`, `PT1H30M` → seconds (negative before).
    static func seconds(_ value: String) -> TimeInterval? {
        var text = Substring(value.uppercased())
        var sign: Double = 1
        if text.hasPrefix("-") { sign = -1; text = text.dropFirst() } else if text.hasPrefix("+") { text = text.dropFirst() }
        guard text.hasPrefix("P") else { return nil }
        text = text.dropFirst()
        var total: Double = 0
        var number = ""
        var inTime = false
        for character in text {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("W", _): total += amount * 604_800
            case ("D", _): total += amount * 86_400
            case ("H", true): total += amount * 3600
            case ("M", true): total += amount * 60
            case ("S", true): total += amount
            default: return nil
            }
        }
        return sign * total
    }

    static func rule(_ value: String, calendar: Calendar) -> Recurrence? {
        var parts: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let item = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if item.count == 2 { parts[item[0].uppercased()] = item[1] }
        }
        guard let frequency = parts["FREQ"].flatMap({ Recurrence.Frequency(rawValue: $0.lowercased()) }) else { return nil }
        let days = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        let weekdays = parts["BYDAY"]?.split(separator: ",").compactMap { days[String($0.suffix(2)).uppercased()] }
        return Recurrence(
            frequency: frequency, interval: parts["INTERVAL"].flatMap(Int.init) ?? 1, count: parts["COUNT"].flatMap(Int.init),
            until: parts["UNTIL"].flatMap { date($0, [:], calendar: calendar)?.0 }, weekdays: weekdays?.isEmpty == false ? weekdays : nil,
            monthDays: parts["BYMONTHDAY"]?.split(separator: ",").compactMap { Int($0) })
    }

    // MARK: Writing

    public static func write(_ events: [Event], calendar: Calendar = .current, now: Date = Date()) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//MP Consulting//Apple Calendar MCP//EN", "CALSCALE:GREGORIAN"]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(escape(event.externalID ?? event.eventID))")
            lines.append("DTSTAMP:\(utc(now))")
            if event.isAllDay {
                let first = calendar.startOfDay(for: event.start)
                let after = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.end)) ?? event.end
                lines.append("DTSTART;VALUE=DATE:\(day(first, calendar))")
                lines.append("DTEND;VALUE=DATE:\(day(after, calendar))")
            } else {
                lines.append("DTSTART:\(utc(event.start))")
                lines.append("DTEND:\(utc(event.end))")
            }
            lines.append("SUMMARY:\(escape(event.title))")
            if let location = event.location { lines.append("LOCATION:\(escape(location))") }
            if let notes = event.notes { lines.append("DESCRIPTION:\(escape(notes))") }
            if let url = event.url { lines.append("URL:\(url)") }
            if event.availability == .free { lines.append("TRANSP:TRANSPARENT") }
            if event.status == .cancelled { lines.append("STATUS:CANCELLED") }
            if let rule = event.recurrence { lines.append("RRULE:\(rrule(rule, calendar: calendar))") }
            if let organizer = event.organizer, let email = organizer.email {
                lines.append("ORGANIZER\(organizer.name.map { ";CN=\(quoted($0))" } ?? ""):mailto:\(email)")
            }
            for attendee in event.attendees {
                guard let email = attendee.email else { continue }
                lines.append("ATTENDEE\(attendee.name.map { ";CN=\(quoted($0))" } ?? ""):mailto:\(email)")
            }
            for alarm in event.alarms {
                lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:\(escape(event.title))"]
                if let at = alarm.at {
                    lines.append("TRIGGER;VALUE=DATE-TIME:\(utc(at))")
                } else {
                    lines.append("TRIGGER:-PT\(max(0, alarm.minutesBefore ?? 0))M")
                }
                lines.append("END:VALARM")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func rrule(_ rule: Recurrence, calendar: Calendar) -> String {
        var parts = ["FREQ=\(rule.frequency.rawValue.uppercased())"]
        if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
        if let count = rule.count { parts.append("COUNT=\(count)") }
        if let until = rule.until { parts.append("UNTIL=\(utc(until))") }
        let names = ["", "SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        if let weekdays = rule.weekdays, !weekdays.isEmpty { parts.append("BYDAY=" + weekdays.filter { (1...7).contains($0) }.map { names[$0] }.joined(separator: ",")) }
        if let days = rule.monthDays, !days.isEmpty { parts.append("BYMONTHDAY=" + days.map(String.init).joined(separator: ",")) }
        return parts.joined(separator: ";")
    }

    static func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", p.year!, p.month!, p.day!, p.hour!, p.minute!, p.second!)
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String { DayFormat.string(date, calendar: calendar).replacingOccurrences(of: "-", with: "") }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "'") + "\"" }

    /// Lines longer than 75 octets continue on the next, after a space, never inside a UTF-8 sequence.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out = ""
        var count = 0
        var limit = 75  // continuation lines hold 74 after their leading space
        for character in line {
            let size = String(character).utf8.count
            if count + size > limit && count > 0 {
                out += "\r\n "
                count = 0
                limit = 74
            }
            out.append(character)
            count += size
        }
        return out
    }
}

extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}

extension String {
    var nilIfEmpty: String? { Optional(self).nilIfEmpty }
}
