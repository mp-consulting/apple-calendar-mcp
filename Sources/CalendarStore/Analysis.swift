import Foundation

/// The hours someone works, for free-time searches.
public struct WorkHours: Codable, Sendable, Hashable {
    /// Minutes after midnight.
    public var start: Int
    public var end: Int
    /// 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>

    public init(start: Int = 9 * 60, end: Int = 18 * 60, weekdays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.start = start
        self.end = end
        self.weekdays = weekdays
    }

    /// "09:30" → 570.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0...24).contains(hour), (0..<60).contains(minute),
            hour * 60 + minute <= 24 * 60
        else { return nil }
        return hour * 60 + minute
    }

    public static func text(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

public enum Busy {
    /// Whether `event` takes the time it covers. All-day events only when marked unavailable or busy on purpose
    /// (out of office, travel); Calendar shows the rest (birthdays, holidays, reminders of a day) as free.
    public static func blocks(_ event: Event) -> Bool {
        guard event.blocksTime else { return false }
        return !event.isAllDay || event.availability == .unavailable
    }

    /// The busy intervals of `events`, merged, each widened by `buffer` on both sides.
    public static func intervals(_ events: [Event], buffer: TimeInterval = 0) -> [DateInterval] {
        let spans = events.filter(blocks).map { DateInterval(start: $0.start.addingTimeInterval(-buffer), end: max($0.end, $0.start).addingTimeInterval(buffer)) }
            .sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for span in spans {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }
}

public enum FreeTime {
    /// Gaps of at least `duration` between busy times within `from..<to`, inside `hours` when given (else the whole
    /// day), starting on a multiple of `step` minutes. Each gap is reported once, whole.
    public static func slots(
        events: [Event], from: Date, to: Date, duration: TimeInterval, hours: WorkHours?, buffer: TimeInterval = 0,
        step: Int = 15, calendar: Calendar = .current
    ) -> [DateInterval] {
        let busy = Busy.intervals(events, buffer: buffer)
        var results: [DateInterval] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day) ?? to }
            let weekday = calendar.component(.weekday, from: day)
            var window: DateInterval
            if let hours {
                guard hours.weekdays.contains(weekday), hours.end > hours.start,
                    let start = calendar.date(byAdding: .minute, value: hours.start, to: day),
                    let end = calendar.date(byAdding: .minute, value: hours.end, to: day)
                else { continue }
                window = DateInterval(start: start, end: end)
            } else {
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
                window = DateInterval(start: day, end: next)
            }
            let start = max(window.start, from)
            let end = min(window.end, to)
            guard end > start else { continue }
            window = DateInterval(start: roundUp(start, step: step, calendar: calendar), end: end)
            guard window.end > window.start else { continue }
            var cursor = window.start
            for interval in busy where interval.end > window.start && interval.start < window.end {
                if interval.start > cursor, interval.start.timeIntervalSince(cursor) >= duration {
                    results.append(DateInterval(start: cursor, end: interval.start))
                }
                cursor = max(cursor, roundUp(interval.end, step: step, calendar: calendar))
            }
            if window.end > cursor, window.end.timeIntervalSince(cursor) >= duration {
                results.append(DateInterval(start: cursor, end: window.end))
            }
        }
        return results
    }

    static func roundUp(_ date: Date, step: Int, calendar: Calendar) -> Date {
        guard step > 1 else { return date }
        let minute = calendar.component(.minute, from: date)
        let second = calendar.component(.second, from: date)
        let over = minute % step
        guard over != 0 || second != 0 else { return date }
        return date.addingTimeInterval(TimeInterval((step - over) * 60 - second))
    }
}

public enum Conflicts {
    /// Pairs of timed events that overlap and both take the time (free, declined and cancelled ones do not count). The
    /// same meeting seen through two calendars (yours and a colleague's shared one: same title, start and end) is
    /// one meeting, not a conflict.
    public static func find(_ events: [Event]) -> [(Event, Event)] {
        let timed = events.filter { Busy.blocks($0) && !$0.isAllDay }.sorted(by: Event.chronological)
        var pairs: [(Event, Event)] = []
        for (index, event) in timed.enumerated() {
            for other in timed[(index + 1)...] {
                guard other.start < event.end else { break }
                let sameMeeting = other.title == event.title && other.start == event.start && other.end == event.end
                if other.end > event.start, other.id != event.id, !sameMeeting { pairs.append((event, other)) }
            }
        }
        return pairs
    }
}

/// Meeting links in an event's URL, location and notes.
public enum VideoLink {
    static let hosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com", "whereby.com",
        "gotomeeting.com", "meet.jit.si", "chime.aws", "bluejeans.com", "around.co", "discord.gg",
    ]

    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func find(in event: Event) -> String? {
        for text in [event.url, event.location, event.notes].compactMap({ $0 }) {
            if let link = find(in: text) { return link }
        }
        return nil
    }

    public static func find(in text: String) -> String? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let host = url.host()?.lowercased() else { continue }
            if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url.absoluteString }
        }
        return nil
    }
}

/// Free-text matching over an event's words, people and places: case and accent insensitive.
public enum EventText {
    public static func matches(_ event: Event, _ query: String, fields: Set<Field> = Set(Field.allCases)) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = text(of: event, fields: fields)
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public enum Field: String, CaseIterable, Sendable {
        case title, location, notes, people
    }

    static func text(of event: Event, fields: Set<Field>) -> String {
        var parts: [String] = []
        if fields.contains(.title) { parts.append(event.title) }
        if fields.contains(.location), let location = event.location { parts.append(location) }
        if fields.contains(.notes), let notes = event.notes { parts.append(notes) }
        if fields.contains(.people) {
            for person in event.attendees + [event.organizer].compactMap({ $0 }) {
                parts.append([person.name, person.email].compactMap { $0 }.joined(separator: " "))
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Whether `person` names (in part) one of the event's attendees or its organizer.
    public static func involves(_ event: Event, _ person: String) -> Bool {
        (event.attendees + [event.organizer].compactMap { $0 }).contains { participant in
            [participant.name, participant.email].compactMap { $0 }.contains {
                $0.range(of: person, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

/// Where time went over a period.
public struct TimeStatistics: Sendable {
    public struct Bucket: Sendable, Equatable {
        public var name: String
        public var hours: Double
        public var events: Int
    }

    public var events: Int
    public var timedHours: Double
    /// Events with at least one other person.
    public var meetings: Int
    public var meetingHours: Double
    public var allDay: Int
    public var recurringShare: Double
    /// Meetings that start within 5 minutes of the end of the previous one.
    public var backToBack: Int
    public var byCalendar: [Bucket]
    public var byWeekday: [Bucket]
    public var byHour: [Bucket]
    public var byPerson: [Bucket]
    public var busiestDays: [Bucket]
    public var longest: [Event]

    public init(events all: [Event], calendar: Calendar = .current, top: Int = 10) {
        let counted = all.filter(\.isAttended)
        let timed = counted.filter { !$0.isAllDay }
        events = counted.count
        allDay = counted.count - timed.count
        timedHours = timed.reduce(0) { $0 + $1.duration } / 3600
        let meetingEvents = timed.filter(\.hasOtherAttendees)
        meetings = meetingEvents.count
        meetingHours = meetingEvents.reduce(0) { $0 + $1.duration } / 3600
        recurringShare = counted.isEmpty ? 0 : Double(counted.filter(\.isRecurring).count) / Double(counted.count)
        let sortedMeetings = meetingEvents.sorted(by: Event.chronological)
        backToBack = zip(sortedMeetings, sortedMeetings.dropFirst()).filter { previous, next in
            let gap = next.start.timeIntervalSince(previous.end)
            return gap >= 0 && gap <= 300 && calendar.isDate(previous.end, inSameDayAs: next.start)
        }.count

        func buckets(_ key: (Event) -> [String]) -> [Bucket] {
            var table: [String: Bucket] = [:]
            for event in timed {
                for name in key(event) {
                    table[name, default: Bucket(name: name, hours: 0, events: 0)].hours += event.duration / 3600
                    table[name]!.events += 1
                }
            }
            return table.values.sorted { $0.hours != $1.hours ? $0.hours > $1.hours : $0.name < $1.name }
        }
        byCalendar = buckets { [$0.calendarTitle] }
        let names = calendar.weekdaySymbols
        byWeekday = buckets { [names[calendar.component(.weekday, from: $0.start) - 1]] }
        byHour = buckets { [String(format: "%02d:00", calendar.component(.hour, from: $0.start))] }.sorted { $0.name < $1.name }
        byPerson = Array(buckets { event in
            event.otherPeople.map(\.displayName)
        }.prefix(top))
        busiestDays = Array(buckets { [DayFormat.string($0.start, calendar: calendar)] }.prefix(5))
        longest = Array(timed.sorted { $0.duration > $1.duration }.prefix(5))
    }
}
