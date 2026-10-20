import Foundation

/// The starts of a repeating event's occurrences, the way Calendar lays them out (used by ``MemoryBackend``; EventKit
/// expands its own).
public struct RecurrenceExpander: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) { self.calendar = calendar }

    /// Occurrence starts of a series beginning at `start`, within `from..<to` (an occurrence counts when it starts
    /// before `to` and ends after `from`, `duration` long). At most `limit` are made.
    public func starts(
        of rule: Recurrence, seriesStart start: Date, duration: TimeInterval, from: Date, to: Date, limit: Int = 5000
    ) -> [Date] {
        var results: [Date] = []
        var produced = 0
        let until = rule.until.map { calendar.startOfDay(for: $0).addingTimeInterval(86_399) }
        for candidate in candidates(rule, start: start) {
            if let until, candidate > until { break }
            if let count = rule.count, produced >= count { break }
            if candidate >= to || results.count >= limit { break }
            produced += 1
            if candidate.addingTimeInterval(max(duration, 1)) > from { results.append(candidate) }
        }
        return results
    }

    /// Every occurrence start from `start` on, in order (lazily: callers stop it).
    func candidates(_ rule: Recurrence, start: Date) -> AnySequence<Date> {
        let calendar = self.calendar
        let time = calendar.dateComponents([.hour, .minute, .second], from: start)
        switch rule.frequency {
        case .daily:
            return AnySequence(sequence(state: 0) { step -> Date? in
                defer { step += 1 }
                return calendar.date(byAdding: .day, value: step * rule.interval, to: start)
            })
        case .weekly:
            let days = (rule.weekdays?.isEmpty == false ? rule.weekdays! : [calendar.component(.weekday, from: start)]).sorted()
            // The week the series starts in, from its first day.
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? calendar.startOfDay(for: start)
            return AnySequence(sequence(state: (week: 0, index: 0)) { state -> Date? in
                while true {
                    guard state.week < 100_000 else { return nil }
                    if state.index >= days.count {
                        state.index = 0
                        state.week += 1
                    }
                    let weekday = days[state.index]
                    state.index += 1
                    guard let week = calendar.date(byAdding: .weekOfYear, value: state.week * rule.interval, to: weekStart) else { return nil }
                    let offset = (weekday - calendar.component(.weekday, from: week) + 7) % 7
                    guard let day = calendar.date(byAdding: .day, value: offset, to: week),
                        let date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
                    else { continue }
                    if date >= start { return date }
                }
            })
        case .monthly:
            let monthDays = rule.monthDays?.isEmpty == false ? rule.monthDays!.sorted() : [calendar.component(.day, from: start)]
            let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
            return AnySequence(sequence(state: (month: 0, index: 0)) { state -> Date? in
                while true {
                    guard state.month < 20_000 else { return nil }
                    if state.index >= monthDays.count {
                        state.index = 0
                        state.month += 1
                    }
                    let wanted = monthDays[state.index]
                    state.index += 1
                    guard let month = calendar.date(byAdding: .month, value: state.month * rule.interval, to: firstMonth),
                        let length = calendar.range(of: .day, in: .month, for: month)?.count
                    else { return nil }
                    // Day 31 skips shorter months, as Calendar does; negative days count from the end.
                    let day = wanted > 0 ? wanted : length + wanted + 1
                    guard (1...length).contains(day) else { continue }
                    var parts = calendar.dateComponents([.year, .month], from: month)
                    parts.day = day
                    parts.hour = time.hour
                    parts.minute = time.minute
                    parts.second = time.second
                    guard let date = calendar.date(from: parts) else { continue }
                    if date >= start { return date }
                }
            })
        case .yearly:
            let parts = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: start)
            let year = calendar.component(.year, from: start)
            return AnySequence(sequence(state: 0) { step -> Date? in
                while step < 10_000 {
                    var wanted = parts
                    wanted.year = year + step * rule.interval
                    step += 1
                    // February 29 only in leap years.
                    if let date = calendar.date(from: wanted), calendar.component(.day, from: date) == parts.day { return date }
                }
                return nil
            })
        }
    }
}
