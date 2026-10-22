import CalendarStore
import Foundation
import MCP

/// A bad or missing tool argument; reported back to the model verbatim.
public struct ToolError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Typed access to tool arguments, tolerant of the shapes models send
/// (numbers as strings, lists as comma-separated strings).
public struct Arguments: Sendable {
    public var values: [String: Value]
    /// The zone dates without an offset are read in (the tool's `time_zone`, else the Mac's).
    public var timeZone: TimeZone = .current
    /// For `today`, `tomorrow` and `now` (tests fix it).
    public var now: Date = Date()

    public init(_ values: [String: Value]?) { self.values = values ?? [:] }

    public func has(_ key: String) -> Bool {
        if let value = values[key], value != .null { return true }
        return false
    }

    public func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null: return nil
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: throw ToolError("\(key) must be a string")
        }
    }

    /// A text field that may be cleared: "" is kept (nil only when absent).
    public func clearableString(_ key: String) throws -> String? {
        if case .string(let s) = values[key] { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return try string(key)
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = try string(key) else { throw ToolError("\(key) is required") }
        return value
    }

    public func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null: return nil
        case .int(let i): return i
        case .double(let d):
            guard let i = Int(exactly: d) else { throw ToolError("\(key) must be an integer") }
            return i
        case .string(let s):
            guard let i = Int(s.trimmingCharacters(in: .whitespaces)) else { throw ToolError("\(key) must be an integer") }
            return i
        default: throw ToolError("\(key) must be an integer")
        }
    }

    /// An integer clamped to `range` (models send 0, negatives and huge counts); `fallback` when absent.
    public func int(_ key: String, default fallback: Int, in range: ClosedRange<Int>) throws -> Int {
        min(range.upperBound, max(range.lowerBound, try int(key) ?? fallback))
    }

    public func bool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil, .null: return nil
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: throw ToolError("\(key) must be true or false")
            }
        default: throw ToolError("\(key) must be true or false")
        }
    }

    /// A list of strings; accepts an array or a comma/semicolon-separated string.
    public func strings(_ key: String) throws -> [String] {
        switch values[key] {
        case nil, .null: return []
        case .array(let items): return try items.map { item -> String in
            guard let s = item.stringValue ?? item.intValue.map(String.init) else { throw ToolError("\(key) must contain strings") }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        case .string(let s):
            return s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: throw ToolError("\(key) must be a list of strings")
        }
    }

    /// Integers from an array or a comma-separated string.
    public func ints(_ key: String) throws -> [Int]? {
        guard has(key) else { return nil }
        if case .array(let items) = values[key] {
            return try items.map { item in
                if let i = item.intValue { return i }
                if let d = item.doubleValue, let i = Int(exactly: d) { return i }
                if let s = item.stringValue, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
                throw ToolError("\(key) must contain integers")
            }
        }
        return try strings(key).map { text in
            guard let i = Int(text) else { throw ToolError("\(key) must contain integers") }
            return i
        }
    }

    /// Event ids (strings; an occurrence is `<id>#<unix seconds>`), duplicates dropped.
    public func refs(_ key: String) throws -> [EventRef] {
        var seen = Set<String>()
        return try strings(key).map { text in
            guard let ref = EventRef(text) else { throw ToolError("invalid event id \"\(text)\"") }
            return ref
        }.filter { seen.insert($0.string).inserted }
    }

    /// Exactly one event id: a list would otherwise act on its first id alone, silently.
    public func ref(_ key: String) throws -> EventRef {
        let refs = try refs(key)
        guard let ref = refs.first else { throw ToolError("\(key) is required") }
        guard refs.count == 1 else { throw ToolError("\(key) takes one event id, not \(refs.count)") }
        return ref
    }

    var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    /// A date: `YYYY-MM-DD` (the start of that day, or its last second with `endOfDay`), a local time
    /// `YYYY-MM-DDTHH:MM[:SS]` in `timeZone`, a full ISO 8601 timestamp with an offset, or `now`, `today`,
    /// `tomorrow`, `yesterday`.
    public func date(_ key: String, endOfDay: Bool = false) throws -> Date? {
        guard let text = try string(key)?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard let date = Self.parseDate(text, endOfDay: endOfDay, calendar: calendar, now: now) else {
            throw ToolError("\(key) must be YYYY-MM-DD, YYYY-MM-DDTHH:MM (local time) or an ISO 8601 date, not \"\(text)\"")
        }
        return date
    }

    /// Whether `key` holds a day without a time (`YYYY-MM-DD`, `today`…).
    public func isDay(_ key: String) throws -> Bool {
        guard let text = try string(key)?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return (text.count == 10 && text.dropFirst(4).first == "-") || ["today", "tomorrow", "yesterday"].contains(text)
    }

    static func parseDate(_ text: String, endOfDay: Bool, calendar: Calendar, now: Date) -> Date? {
        let lower = text.lowercased()
        let dayOffset: Int? = switch lower {
        case "today": 0
        case "tomorrow": 1
        case "yesterday": -1
        default: nil
        }
        if lower == "now" { return now }
        if let dayOffset, let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) {
            return endOfDay ? day.addingTimeInterval(86_399) : day
        }
        if text.count == 10, let day = DayFormat.date(text, calendar: calendar) {
            return endOfDay ? calendar.date(byAdding: .day, value: 1, to: day)!.addingTimeInterval(-1) : day
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        // Local time without an offset.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// A time zone by name (`Europe/Paris`).
    public func timeZone(_ key: String) throws -> TimeZone? {
        guard let zone = try string(key) else { return nil }
        guard let timeZone = TimeZone(identifier: zone) else { throw ToolError("\(key) \"\(zone)\" is not a time zone (use names like Europe/Paris)") }
        return timeZone
    }

    /// `HH:MM` as minutes after midnight.
    public func timeOfDay(_ key: String) throws -> Int? {
        guard let text = try string(key) else { return nil }
        guard let minutes = WorkHours.minutes(text.trimmingCharacters(in: .whitespaces)) else { throw ToolError("\(key) must be HH:MM") }
        return minutes
    }

    /// Weekdays by name or number (1 = Sunday … 7 = Saturday): `["mon", "wed"]`, `"monday,friday"`, `[2, 4]`.
    public func weekdays(_ key: String) throws -> [Int]? {
        guard has(key) else { return nil }
        let names = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
        var days: [Int] = []
        let items: [String]
        if case .array(let values) = values[key] {
            items = values.compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
        } else {
            items = try strings(key)
        }
        for item in items {
            let text = item.lowercased().trimmingCharacters(in: .whitespaces)
            if let number = Int(text), (1...7).contains(number) {
                days.append(number)
            } else if let day = names[String(text.prefix(3))] {
                days.append(day)
            } else {
                throw ToolError("\(key): \"\(item)\" is not a weekday")
            }
        }
        return Array(Set(days)).sorted()
    }
}

/// An ordered JSON value: keys keep insertion order so ids and subjects come first.
public indirect enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (lhs: JSON, rhs: JSON) -> Bool { lhs.serialized() == rhs.serialized() }

    public static func obj(_ pairs: [(String, JSON?)]) -> JSON {
        .object(pairs.compactMap { key, value in value.map { (key, $0) } })
    }

    /// This object with `key` added last (anything else is returned as it is).
    func adding(_ key: String, _ value: JSON) -> JSON {
        guard case .object(let pairs) = self else { return self }
        return .object(pairs + [(key, value)])
    }

    public func serialized(pretty: Bool = false) -> String {
        if pretty { return prettyText() }
        // Tool output: UTF-8 bytes into one buffer, and strings that need no escaping copied whole. Appending scalar
        // by scalar to a String made writing a page of results take longer than finding them.
        return String(decoding: compactUTF8(), as: UTF8.self)
    }

    /// Compact output as UTF-8 bytes (see `serialized`).
    func compactUTF8() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        writeCompact(into: &out)
        return out
    }

    /// Indented output, written the straightforward way.
    func prettyText() -> String {
        var out = ""
        write(into: &out, indent: 0)
        return out
    }

    private func writeCompact(into out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let i): out.append(contentsOf: String(i).utf8)
        case .double(let d): out.append(contentsOf: (d.isFinite ? String(d) : "null").utf8)
        case .string(let s): JSON.escape(s, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                item.writeCompact(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let pairs):
            out.append(UInt8(ascii: "{"))
            for (index, (key, value)) in pairs.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                JSON.escape(key, into: &out)
                out.append(UInt8(ascii: ":"))
                value.writeCompact(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func escape(_ text: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        var text = text
        text.withUTF8 { bytes in
            var start = 0
            for index in 0..<bytes.count {
                let byte = bytes[index]
                guard byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") else { continue }
                out.append(contentsOf: bytes[start..<index])
                switch byte {
                case UInt8(ascii: "\""): out.append(contentsOf: #"\""#.utf8)
                case UInt8(ascii: "\\"): out.append(contentsOf: #"\\"#.utf8)
                case 0x0A: out.append(contentsOf: #"\n"#.utf8)
                case 0x0D: out.append(contentsOf: #"\r"#.utf8)
                case 0x09: out.append(contentsOf: #"\t"#.utf8)
                default:
                    let hex = Array("0123456789abcdef".utf8)
                    out.append(contentsOf: #"\u00"#.utf8)
                    out.append(hex[Int(byte >> 4)])
                    out.append(hex[Int(byte & 0xF)])
                }
                start = index + 1
            }
            out.append(contentsOf: bytes[start...])
        }
        out.append(UInt8(ascii: "\""))
    }

    private func write(into out: inout String, indent: Int) {
        let newline = "\n"
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += d.isFinite ? String(d) : "null"
        case .string(let s): JSON.escape(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, indent: indent + 1)
                if index < items.count - 1 { out += "," }
                out += newline
            }
            out += closePad + "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{" + newline
            for (index, (key, value)) in pairs.enumerated() {
                out += pad
                JSON.escape(key, into: &out)
                out += ": "
                value.write(into: &out, indent: indent + 1)
                if index < pairs.count - 1 { out += "," }
                out += newline
            }
            out += closePad + "}"
        }
    }

    private static func escape(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}


/// Shared formatting of calendar objects for tool output.
enum Render {
    static func date(_ date: Date) -> JSON { .string(isoDate(date)) }

    /// Local time to the nearest second, then `Z` or `±hh:mm`.
    static func isoDate(_ date: Date) -> String {
        var time = time_t(date.timeIntervalSince1970.rounded())
        var parts = tm()
        localtime_r(&time, &parts)
        let offset = parts.tm_gmtoff
        let zone = offset == 0 ? "Z" : String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday),
            Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec)) + zone
    }

    static func day(_ date: Date) -> JSON { .string(DayFormat.string(date)) }

    static func truncate(_ text: String, _ limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    static func hours(_ value: Double) -> JSON { .double((value * 10).rounded() / 10) }

    /// One event in a list: what is needed to recognize it and act on it.
    static func event(_ event: Event) -> JSON {
        let organizer = event.organizer.flatMap { $0.isCurrentUser || event.attendees.isEmpty ? nil : $0 }
        let mine = event.myStatus.flatMap { $0 == .accepted ? nil : $0 }
        return .obj([
            ("id", .string(event.id)),
            ("title", .string(event.title)),
        ] + times(event) + [
            ("calendar", .string(event.calendarTitle)),
            ("location", event.location.map { .string(truncate($0, 120)) }),
            ("video", VideoLink.find(in: event).map(JSON.string)),
            ("availability", event.availability == .busy ? nil : .string(event.availability.rawValue)),
            ("status", event.status == .cancelled || event.status == .tentative ? .string(event.status.rawValue) : nil),
            ("my_status", mine.map { .string($0.rawValue) }),
            ("organizer", organizer.map { .string($0.formatted) }),
            ("attendees", event.attendees.isEmpty ? nil : .int(Int64(event.attendees.count))),
            ("recurring", event.isRecurring ? .bool(true) : nil),
        ])
    }

    static func times(_ event: Event) -> [(String, JSON?)] {
        if event.isAllDay {
            let first = DayFormat.string(event.start)
            let last = DayFormat.string(max(event.start, event.end.addingTimeInterval(event.end > event.start ? -1 : 0)))
            return [("date", .string(first)), ("end_date", last == first ? nil : .string(last)), ("all_day", .bool(true))]
        }
        return [("start", date(event.start)), ("end", date(event.end))]
    }

    /// One event in full.
    static func detail(_ event: Event, notesLimit: Int) -> JSON {
        guard case .object(var pairs) = self.event(event) else { return self.event(event) }
        pairs.removeAll { $0.0 == "attendees" || $0.0 == "organizer" }
        let extra: [(String, JSON?)] = [
            ("time_zone", event.timeZone.flatMap { $0 == TimeZone.current.identifier ? nil : .string($0) }),
            ("notes", event.notes.flatMap { $0.isEmpty ? nil : .string(truncate($0, notesLimit)) }),
            ("url", event.url.map(JSON.string)),
            ("organizer", event.organizer.map(participant)),
            ("attendees", event.attendees.isEmpty ? nil : .array(event.attendees.map(participant))),
            ("alarms", event.alarms.isEmpty ? nil : .array(event.alarms.map(alarm))),
            ("repeat", event.recurrence.map { .string($0.summary) }),
            ("detached", event.isDetached ? .bool(true) : nil),
            ("series_id", event.isRecurring ? .string(event.eventID) : nil),
            ("created", event.created.map(date)),
            ("modified", event.modified.map(date)),
            ("uid", event.externalID.map(JSON.string)),
            ("link", .string(event.calendarLink)),
        ]
        return .object(pairs + extra.compactMap { key, value in value.map { (key, $0) } })
    }

    static func participant(_ person: Participant) -> JSON {
        .obj([
            ("name", person.name.map(JSON.string)),
            ("email", person.email.map(JSON.string)),
            ("status", person.status == .unknown ? nil : .string(person.status.rawValue)),
            ("role", person.role == .required || person.role == .unknown ? nil : .string(person.role.rawValue)),
            ("kind", person.kind == .person || person.kind == .unknown ? nil : .string(person.kind.rawValue)),
            ("me", person.isCurrentUser ? .bool(true) : nil),
        ])
    }

    static func alarm(_ alarm: Alarm) -> JSON {
        if let at = alarm.at { return .obj([("at", date(at))]) }
        return .obj([("minutes_before", .int(Int64(alarm.minutesBefore ?? 0)))])
    }

    static func calendar(_ calendar: CalendarInfo) -> JSON {
        .obj([
            ("id", .string(calendar.id)),
            ("title", .string(calendar.title)),
            ("account", .string(calendar.account)),
            ("kind", .string(calendar.kind.rawValue)),
            ("color", .string(calendar.color)),
            ("read_only", calendar.writable ? nil : .bool(true)),
            ("default", calendar.isDefault ? .bool(true) : nil),
        ])
    }

    static func slot(_ interval: DateInterval) -> JSON {
        .obj([("start", date(interval.start)), ("end", date(interval.end)), ("minutes", .int(Int64(interval.duration / 60)))])
    }
}

/// JSON Schema helpers for tool definitions.
enum Schema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String, enum values: [String]? = nil) -> Value {
        var schema: [String: Value] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> Value {
        var schema: [String: Value] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> Value {
        .object(["type": "boolean", "description": .string(description)])
    }

    static func strings(_ description: String) -> Value {
        .object(["type": "array", "items": ["type": "string"], "description": .string(description)])
    }

    static func integers(_ description: String) -> Value {
        .object(["type": "array", "items": ["type": "integer"], "description": .string(description)])
    }

    static func ids(_ description: String) -> Value {
        .object(["type": "array", "items": ["type": "string"], "minItems": 1, "description": .string(description)])
    }

    static let date = "YYYY-MM-DD, YYYY-MM-DDTHH:MM (local time), an ISO 8601 timestamp, or today/tomorrow/now"
}
