import Foundation
import Testing

@testable import CalendarStore

/// A fixed calendar so dates do not depend on the Mac running the tests.
let paris: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    calendar.firstWeekday = 2
    return calendar
}()

func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    paris.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

let work = CalendarInfo(id: "work", title: "Work", account: "iCloud", kind: .calDAV, color: "#0A84FF", writable: true, isDefault: true)
let holidays = CalendarInfo(id: "holidays", title: "Holidays", account: "Subscribed", kind: .subscription, color: "#FF9F0A", writable: false)

func event(_ id: String, _ title: String, _ start: Date, minutes: Int = 60, calendar: CalendarInfo = work) -> Event {
    Event(eventID: id, calendarID: calendar.id, calendarTitle: calendar.title, title: title, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))
}

@Suite struct EventRefTests {
    @Test func plainIDRoundTrips() {
        let ref = EventRef("ABC:123")
        #expect(ref?.eventID == "ABC:123")
        #expect(ref?.occurrence == nil)
        #expect(ref?.string == "ABC:123")
    }

    @Test func occurrenceSuffixIsParsed() throws {
        let ref = try #require(EventRef("ABC:123#1761040800"))
        #expect(ref.eventID == "ABC:123")
        #expect(ref.occurrence == Date(timeIntervalSince1970: 1_761_040_800))
        #expect(ref.string == "ABC:123#1761040800")
    }

    @Test func hashWithoutDigitsStaysInTheID() {
        #expect(EventRef("meeting#notes")?.eventID == "meeting#notes")
        #expect(EventRef("   ") == nil)
    }
}

@Suite struct RecurrenceTests {
    let expander = RecurrenceExpander(calendar: paris)

    @Test func weeklyOnTwoDaysWithCount() {
        let rule = Recurrence(frequency: .weekly, count: 4, weekdays: [2, 4])  // Mon, Wed
        let starts = expander.starts(of: rule, seriesStart: at(2026, 10, 19, 9), duration: 3600, from: at(2026, 10, 1), to: at(2026, 12, 31))
        #expect(starts == [at(2026, 10, 19, 9), at(2026, 10, 21, 9), at(2026, 10, 26, 9), at(2026, 10, 28, 9)])
    }

    @Test func everyOtherWeekUntil() {
        let rule = Recurrence(frequency: .weekly, interval: 2, until: at(2026, 11, 16))
        let starts = expander.starts(of: rule, seriesStart: at(2026, 10, 19, 9), duration: 3600, from: at(2026, 10, 1), to: at(2027, 1, 1))
        #expect(starts == [at(2026, 10, 19, 9), at(2026, 11, 2, 9), at(2026, 11, 16, 9)])
    }

    @Test func monthlyOnThe31stSkipsShortMonths() {
        let rule = Recurrence(frequency: .monthly, count: 3)
        let starts = expander.starts(of: rule, seriesStart: at(2026, 10, 31, 8), duration: 1800, from: at(2026, 10, 1), to: at(2027, 6, 1))
        #expect(starts == [at(2026, 10, 31, 8), at(2026, 12, 31, 8), at(2027, 1, 31, 8)])
    }

    @Test func yearlyOnFebruary29OnlyInLeapYears() {
        let rule = Recurrence(frequency: .yearly, count: 2)
        let starts = expander.starts(of: rule, seriesStart: at(2028, 2, 29), duration: 86_399, from: at(2028, 1, 1), to: at(2040, 1, 1))
        #expect(starts == [at(2028, 2, 29), at(2032, 2, 29)])
    }

    @Test func countIncludesOccurrencesBeforeTheWindow() {
        let rule = Recurrence(frequency: .daily, count: 5)
        let starts = expander.starts(of: rule, seriesStart: at(2026, 10, 1, 9), duration: 3600, from: at(2026, 10, 4), to: at(2026, 10, 30))
        #expect(starts == [at(2026, 10, 4, 9), at(2026, 10, 5, 9)])
    }

    @Test func summaryReadsLikeCalendar() {
        let rule = Recurrence(frequency: .weekly, interval: 2, weekdays: [4, 2])
        #expect(rule.summary == "every 2 weeks on Mon, Wed")
    }
}

@Suite struct MemoryBackendTests {
    func standup() -> MemoryBackend {
        var series = event("standup", "Standup", at(2026, 10, 19, 9, 30), minutes: 15)
        series.recurrence = Recurrence(frequency: .daily, count: 5)
        return MemoryBackend(calendars: [work, holidays], events: [series, event("review", "Review", at(2026, 10, 20, 14))], calendar: paris)
    }

    @Test func repeatingEventsExpandInRange() throws {
        let events = try standup().events(from: at(2026, 10, 20), to: at(2026, 10, 22), calendarIDs: nil)
        #expect(events.map(\.title) == ["Standup", "Review", "Standup"])
        #expect(events[0].ref.occurrence == at(2026, 10, 20, 9, 30))
        #expect(events[1].ref.occurrence == nil)
    }

    @Test func changingOneOccurrenceDetachesIt() throws {
        let backend = standup()
        let ref = EventRef(eventID: "standup", occurrence: at(2026, 10, 21, 9, 30))
        let moved = try backend.update(ref, EventChange(start: at(2026, 10, 21, 11)), span: .thisEvent)
        #expect(moved.isDetached)
        #expect(moved.end == at(2026, 10, 21, 11, 15))
        let day = try backend.events(from: at(2026, 10, 21), to: at(2026, 10, 22), calendarIDs: nil)
        #expect(day.map(\.start) == [at(2026, 10, 21, 11)])
        // Still found by its original start.
        #expect(try backend.event(ref)?.start == at(2026, 10, 21, 11))
    }

    @Test func changingFutureOccurrencesSplitsTheSeries() throws {
        let backend = standup()
        let ref = EventRef(eventID: "standup", occurrence: at(2026, 10, 22, 9, 30))
        _ = try backend.update(ref, EventChange(title: "Daily"), span: .futureEvents)
        let week = try backend.events(from: at(2026, 10, 19), to: at(2026, 10, 26), calendarIDs: nil).filter { $0.title != "Review" }
        #expect(week.map(\.title) == ["Standup", "Standup", "Standup", "Daily", "Daily"])
    }

    @Test func deletingOneOccurrenceLeavesTheRest() throws {
        let backend = standup()
        try backend.delete(EventRef(eventID: "standup", occurrence: at(2026, 10, 20, 9, 30)), span: .thisEvent)
        let week = try backend.events(from: at(2026, 10, 19), to: at(2026, 10, 26), calendarIDs: ["work"]).filter { $0.title == "Standup" }
        #expect(week.count == 4)
    }

    @Test func readOnlyCalendarsRefuseChanges() throws {
        let backend = MemoryBackend(calendars: [work, holidays], events: [event("h", "Holiday", at(2026, 11, 1), calendar: holidays)], calendar: paris)
        #expect(throws: CalendarError.self) { try backend.delete(EventRef(eventID: "h"), span: .thisEvent) }
        #expect(throws: CalendarError.self) { _ = try backend.create(EventDraft(title: "x", start: at(2026, 11, 2), end: at(2026, 11, 2, 1), calendarID: "holidays")) }
    }

    @Test func newEventsGoToTheDefaultCalendar() throws {
        let created = try standup().create(EventDraft(title: "Lunch", start: at(2026, 10, 23, 12), end: at(2026, 10, 23, 13)))
        #expect(created.calendarID == "work")
        #expect(created.availability == .busy)
    }

    @Test func noAccessThrows() {
        let backend = standup()
        backend.setAccess(.denied)
        #expect(throws: CalendarError.self) { _ = try backend.calendars() }
    }
}

@Suite struct AnalysisTests {
    @Test func freeTimeInsideWorkingHoursWithBuffer() {
        let events = [event("a", "A", at(2026, 10, 20, 10), minutes: 60), event("b", "B", at(2026, 10, 20, 14), minutes: 90)]
        let slots = FreeTime.slots(
            events: events, from: at(2026, 10, 20), to: at(2026, 10, 21), duration: 3600, hours: WorkHours(), buffer: 600, calendar: paris)
        #expect(slots.map(\.start) == [at(2026, 10, 20, 11, 15), at(2026, 10, 20, 15, 45)])
        #expect(slots.map(\.end) == [at(2026, 10, 20, 13, 50), at(2026, 10, 20, 18)])
    }

    @Test func freeTimeSkipsWeekendsAndIgnoresFreeEvents() {
        var lunch = event("l", "Lunch", at(2026, 10, 23, 12))
        lunch.availability = .free
        let slots = FreeTime.slots(events: [lunch], from: at(2026, 10, 23), to: at(2026, 10, 26), duration: 7200, hours: WorkHours(), calendar: paris)
        #expect(slots.count == 1)  // Friday only, whole day
        #expect(slots.first?.start == at(2026, 10, 23, 9))
    }

    @Test func declinedAndAllDayEventsDoNotBlock() {
        var declined = event("d", "Declined", at(2026, 10, 20, 9))
        declined.organizer = Participant(name: "Boss", email: "boss@example.com")
        declined.attendees = [Participant(name: "Me", email: "me@example.com", status: .declined, isCurrentUser: true)]
        var allDay = event("x", "Conference", at(2026, 10, 20))
        allDay.isAllDay = true
        allDay.end = at(2026, 10, 20, 23, 59)
        #expect(Busy.intervals([declined, allDay]).isEmpty)
    }

    @Test func conflictsFindOverlaps() {
        let events = [
            event("a", "A", at(2026, 10, 20, 10), minutes: 60), event("b", "B", at(2026, 10, 20, 10, 30), minutes: 60),
            event("c", "C", at(2026, 10, 20, 11, 15), minutes: 30),
        ]
        let pairs = Conflicts.find(events)
        #expect(pairs.map { "\($0.0.title)+\($0.1.title)" } == ["A+B", "B+C"])
    }

    @Test func theSameMeetingInTwoCalendarsIsNoConflict() {
        let mine = event("a", "Weekly team", at(2026, 10, 26, 10))
        var shared = event("b", "Weekly team", at(2026, 10, 26, 10))
        shared.calendarID = "colleague"
        #expect(Conflicts.find([mine, shared]).isEmpty)
        #expect(Conflicts.find([mine, event("c", "Other call", at(2026, 10, 26, 10, 30))]).count == 1)
    }

    @Test func videoLinksAreFoundInNotes() {
        var call = event("v", "Call", at(2026, 10, 20, 10))
        call.notes = "Agenda attached.\nJoin: https://us02web.zoom.us/j/123456789?pwd=abc\nThanks"
        #expect(VideoLink.find(in: call) == "https://us02web.zoom.us/j/123456789?pwd=abc")
        call.notes = "See https://example.com/agenda"
        #expect(VideoLink.find(in: call) == nil)
    }

    @Test func textMatchingIgnoresCaseAndAccents() {
        var meeting = event("m", "Réunion budget", at(2026, 10, 20, 10))
        meeting.attendees = [Participant(name: "Zoë Martin", email: "zoe@example.com")]
        #expect(EventText.matches(meeting, "reunion BUDGET"))
        #expect(EventText.involves(meeting, "zoe"))
        #expect(!EventText.matches(meeting, "budget forecast"))
    }

    @Test func statisticsCountMeetingsAndBackToBack() {
        var a = event("a", "1:1", at(2026, 10, 20, 10), minutes: 30)
        var b = event("b", "Sync", at(2026, 10, 20, 10, 30), minutes: 60)
        let me = Participant(name: "Me", email: "me@example.com", status: .accepted, isCurrentUser: true)
        a.attendees = [me, Participant(name: "Anna", email: "anna@example.com")]
        b.attendees = [me, Participant(name: "Anna", email: "anna@example.com"), Participant(name: "Ben", email: "ben@example.com")]
        let focus = event("f", "Focus", at(2026, 10, 21, 9), minutes: 120)
        let stats = TimeStatistics(events: [a, b, focus], calendar: paris)
        #expect(stats.meetings == 2)
        #expect(stats.meetingHours == 1.5)
        #expect(stats.timedHours == 3.5)
        #expect(stats.backToBack == 1)
        #expect(stats.byPerson.first == TimeStatistics.Bucket(name: "Anna", hours: 1.5, events: 2))
    }
}

@Suite struct ICSTests {
    let invitation = """
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        BEGIN:VTIMEZONE\r
        TZID:W. Europe Standard Time\r
        END:VTIMEZONE\r
        BEGIN:VEVENT\r
        UID:040000008200E00074C5B7101A82E008\r
        SUMMARY:Quarterly review\\, Q4\r
        DTSTART;TZID=W. Europe Standard Time:20261022T140000\r
        DTEND;TZID=W. Europe Standard Time:20261022T153000\r
        LOCATION:Room 4\r
        DESCRIPTION:Agenda:\\n1. Numbers\\n2. Plans with a very long line that goes on and on so it get\r
         s folded by the sender\r
        ORGANIZER;CN="Anna Berg":mailto:anna@example.com\r
        ATTENDEE;CN=Ben;PARTSTAT=NEEDS-ACTION:mailto:ben@example.com\r
        RRULE:FREQ=WEEKLY;COUNT=3;BYDAY=TH\r
        BEGIN:VALARM\r
        TRIGGER:-PT15M\r
        END:VALARM\r
        END:VEVENT\r
        END:VCALENDAR\r

        """

    @Test func readsAnOutlookInvitation() throws {
        let items = try ICS.parse(invitation, calendar: paris)
        let item = try #require(items.first)
        #expect(item.isInvitation)
        #expect(item.uid == "040000008200E00074C5B7101A82E008")
        #expect(item.draft.title == "Quarterly review, Q4")
        #expect(item.draft.start == at(2026, 10, 22, 14))
        #expect(item.draft.end == at(2026, 10, 22, 15, 30))
        #expect(item.draft.notes?.contains("goes on and on so it gets folded") == true)
        #expect(item.draft.alarms == [Alarm(minutesBefore: 15)])
        #expect(item.draft.recurrence == Recurrence(frequency: .weekly, count: 3, weekdays: [5]))
        #expect(item.organizer == "Anna Berg <anna@example.com>")
        #expect(item.attendees == ["Ben <ben@example.com>"])
    }

    @Test func allDayEventsEndOnTheirLastDay() throws {
        let text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Trip\nDTSTART;VALUE=DATE:20261102\nDTEND;VALUE=DATE:20261105\nEND:VEVENT\nEND:VCALENDAR\n"
        let draft = try #require(try ICS.parse(text, calendar: paris).first?.draft)
        #expect(draft.isAllDay)
        #expect(DayFormat.string(draft.start, calendar: paris) == "2026-11-02")
        #expect(DayFormat.string(draft.end, calendar: paris) == "2026-11-04")
    }

    @Test func writtenEventsReadBack() throws {
        var original = event("w", "Planning; long title, with commas — and accents: été", at(2026, 10, 22, 9), minutes: 45)
        original.notes = "Line one\nLine two"
        original.alarms = [Alarm(minutesBefore: 10)]
        original.recurrence = Recurrence(frequency: .weekly, interval: 2, weekdays: [5])
        let text = ICS.write([original], calendar: paris)
        #expect(text.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let back = try #require(try ICS.parse(text, calendar: paris).first)
        #expect(back.draft.title == original.title)
        #expect(back.draft.start == original.start)
        #expect(back.draft.end == original.end)
        #expect(back.draft.notes == original.notes)
        #expect(back.draft.alarms == original.alarms)
        #expect(back.draft.recurrence == original.recurrence)
    }

    @Test func notACalendarFile() {
        #expect(throws: CalendarError.self) { _ = try ICS.parse("hello", calendar: paris) }
    }
}

@Suite struct BridgeTests {
    /// A short path: Unix socket paths are limited to 104 bytes.
    func socketURL() -> URL { URL(filePath: "/tmp/acm-\(UUID().uuidString.prefix(8))/bridge.sock") }

    @Test func requestsTravelOverTheSocket() throws {
        let backend = MemoryBackend(calendars: [work], events: [event("e", "Design review", at(2026, 10, 20, 14))], calendar: paris)
        let url = socketURL()
        let host = BridgeHost(socket: url, backend: backend, requirement: .anyProcessForTesting, info: BridgeInfo(version: "test", pid: 1)) { request, _ in
            request.title == "yes" ? .approved : .denied
        }
        try host.start()
        defer {
            host.stop()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let client = BridgeClient(socket: url, requirement: .anyProcessForTesting, launcher: nil)
        let remote = BridgeBackend(client: client)
        #expect(remote.access() == .granted)
        #expect(try remote.calendars() == [work])
        let events = try remote.events(from: at(2026, 10, 20), to: at(2026, 10, 21), calendarIDs: nil)
        #expect(events.map(\.title) == ["Design review"])
        let created = try remote.create(EventDraft(title: "Lunch", start: at(2026, 10, 20, 12), end: at(2026, 10, 20, 13)))
        #expect(try backend.event(created.ref)?.title == "Lunch")
        try remote.delete(created.ref, span: .thisEvent)
        #expect(try remote.event(created.ref) == nil)
        // Errors come back as errors.
        #expect(throws: CalendarError.self) { try remote.delete(EventRef(eventID: "missing"), span: .thisEvent) }
        let approval = ApprovalRequest(tool: "delete_event", client: "test", kind: .delete, title: "yes", items: [])
        #expect(try client.requestApproval(approval, timeout: 5) == .approved)
        var refused = approval
        refused.title = "no"
        #expect(try client.requestApproval(refused, timeout: 5) == .denied)
        // The socket is owner-only.
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode.map { $0 & 0o077 } == 0)
    }

    @Test func nobodyListeningWithoutAppToOpen() {
        let client = BridgeClient(socket: socketURL(), requirement: .anyProcessForTesting, launcher: nil)
        #expect(!client.isAppRunning)
        if case .unavailable = BridgeBackend(client: client).access() {} else { Issue.record("expected unavailable") }
    }

    @Test func hostRefusesCodeThatIsNotOurs() throws {
        let url = socketURL()
        let backend = MemoryBackend(calendars: [work], calendar: paris)
        // A requirement no test runner meets.
        let strict = PeerRequirement(text: "identifier \"com.example.nobody\" and anchor apple")
        let host = BridgeHost(socket: url, backend: backend, requirement: strict, info: BridgeInfo(version: "test", pid: 1)) { _, _ in .approved }
        try host.start()
        defer {
            host.stop()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let client = BridgeClient(socket: url, requirement: .anyProcessForTesting, launcher: nil)
        #expect(throws: CalendarError.self) { _ = try BridgeBackend(client: client).calendars() }
        #expect(host.refusedPeers == 1)
    }
}
