import CalendarStore
import Foundation

/// A made-up working week around `now`: repeating meetings, a conflict, an unanswered invitation, focus time,
/// personal events, a read-only holiday calendar. People and addresses are invented (example.com).
public enum StandardFixture {
    public static let work = CalendarInfo(id: "cal-work", title: "Work", account: "iCloud", kind: .calDAV, color: "#0A84FF", writable: true, isDefault: true)
    public static let personal = CalendarInfo(id: "cal-personal", title: "Personal", account: "iCloud", kind: .calDAV, color: "#30D158", writable: true)
    public static let family = CalendarInfo(id: "cal-family", title: "Family", account: "Google", kind: .calDAV, color: "#FF9F0A", writable: true)
    public static let holidays = CalendarInfo(id: "cal-holidays", title: "Holidays", account: "Subscribed Calendars", kind: .subscription, color: "#FF375F", writable: false)

    public static let calendars = [work, personal, family, holidays]

    static let me = Participant(name: "Alex Morgan", email: "alex@example.com", status: .accepted, role: .required, isCurrentUser: true)

    static func person(_ name: String, _ status: Participant.Status = .accepted) -> Participant {
        Participant(name: name, email: name.lowercased().split(separator: " ").joined(separator: ".") + "@example.com", status: status)
    }

    public static func events(now: Date = Date(), calendar: Calendar = .current) -> [Event] {
        let today = calendar.startOfDay(for: now)
        // The Monday of this week (or today when it is one).
        let weekday = calendar.component(.weekday, from: today)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today)!
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0, from base: Date? = nil) -> Date {
            let start = calendar.date(byAdding: .day, value: day, to: base ?? monday)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)!
        }
        var id = 0
        func make(
            _ title: String, _ start: Date, minutes: Int, in info: CalendarInfo = work, location: String? = nil, notes: String? = nil,
            url: String? = nil, people: [Participant] = [], organizer: Participant? = nil, repeats: Recurrence? = nil,
            availability: Availability = .busy, allDay: Bool = false
        ) -> Event {
            id += 1
            return Event(
                eventID: "DEMO-\(id)", externalID: "demo-\(id)@example.com", calendarID: info.id, calendarTitle: info.title, title: title,
                start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60) - (allDay ? 1 : 0)), isAllDay: allDay,
                timeZone: allDay ? nil : calendar.timeZone.identifier, location: location, notes: notes, url: url, availability: availability,
                organizer: people.isEmpty ? nil : (organizer ?? me), attendees: people.isEmpty ? [] : [me] + people,
                alarms: allDay ? [] : [Alarm(minutesBefore: 10)], recurrence: repeats, created: monday.addingTimeInterval(-30 * 86_400))
        }
        let anna = person("Anna Berg"), ben = person("Ben Okafor"), chloe = person("Chloé Martin", .tentative)
        let dev = person("Dev Patel"), emma = person("Emma Schulz", .pending), farid = person("Farid Haddad", .declined)
        let client = Participant(name: "Grace Liu", email: "grace@northwind.example.com", status: .accepted, role: .chair)
        var invitation = make(
            "Quarterly planning with Northwind", at(3, 14), minutes: 90, location: "Northwind HQ, Room 4",
            notes: "Agenda: Q1 roadmap, pricing, support hours.", people: [client, anna], organizer: client)
        invitation.attendees = invitation.attendees.map { $0.isCurrentUser ? Participant(name: me.name, email: me.email, status: .pending, isCurrentUser: true) : $0 }
        return [
            make("Team standup", at(0, 9, 30), minutes: 15, url: "https://meet.example.com/standup", people: [anna, ben, dev],
                 repeats: Recurrence(frequency: .weekly, weekdays: [2, 3, 4, 5, 6])),
            make("1:1 with Anna", at(0, 11), minutes: 30, location: "Small meeting room", people: [anna], repeats: Recurrence(frequency: .weekly)),
            make("Design review: onboarding", at(1, 14), minutes: 60, notes: "Prototype v3. Join: https://us02web.zoom.us/j/5550101?pwd=demo",
                 people: [anna, chloe, dev, farid]),
            make("Focus: pricing proposal", at(1, 9, 45), minutes: 120, notes: "Draft the proposal for Northwind."),
            make("Customer call: Fabrikam", at(2, 10), minutes: 60, url: "https://teams.microsoft.com/l/meetup-join/demo", people: [person("Hana Sato")]),
            make("Engineering sync", at(2, 10, 30), minutes: 45, people: [ben, dev, emma]),
            invitation,
            make("Lunch with Ben", at(2, 12, 30), minutes: 60, in: personal, location: "Taberna do Mercado", people: [ben]),
            make("Dentist", at(4, 16), minutes: 45, in: personal, location: "12 Harbour Street"),
            make("Swimming lessons", at(3, 18), minutes: 60, in: family, location: "City Pool", repeats: Recurrence(frequency: .weekly)),
            make("Sprint retro", at(4, 15), minutes: 45, people: [anna, ben, chloe, dev]),
            make("Product offsite", at(8, 0), minutes: 2 * 1440, location: "Lisbon", availability: .unavailable, allDay: true),
            make("Founders' Day", at(4, 0), minutes: 1440, in: holidays, availability: .free, allDay: true),
            make("Mum's birthday", at(5, 0), minutes: 1440, in: family, availability: .free, allDay: true),
        ]
    }

    public static func backend(now: Date = Date(), calendar: Calendar = .current) -> MemoryBackend {
        MemoryBackend(calendars: calendars, events: events(now: now, calendar: calendar), calendar: calendar)
    }
}
