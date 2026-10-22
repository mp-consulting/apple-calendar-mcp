import CalendarFixtures
import CalendarStore
import Foundation
import MCP
import Testing

@testable import CalendarMCPKit

@Suite struct AvailabilityTests {
    @Test func otherTimeZoneKeepsOnlyTheirWorkingHours() async throws {
        let harness = try Harness()
        // Someone whose day runs 09:00–17:00 three hours ahead of the Mac: only the first part of our day overlaps.
        let ahead = TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT(for: now) + 3 * 3600)!
        var calendar = Calendar.current
        calendar.timeZone = ahead
        let result = try await harness.call("find_free_time", [
            "start": "2026-10-23", "end": "2026-10-23", "duration_minutes": 60,
            "other_time_zone": .string(ahead.identifier), "other_hours": "09:00-17:00", "format": "text",
        ])
        let slots = result["slots"] as? [[String: Any]] ?? []
        #expect(!slots.isEmpty)
        // Every slot ends by 17:00 their time, 14:00 here.
        for slot in slots {
            let end = try #require((slot["end"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
            #expect(end <= day(23, 14))
        }
        let text = try #require(result["text"] as? String)
        #expect(text.split(separator: "\n").count == 1)
        #expect(text.contains("("))
        #expect(await harness.failure("find_free_time", ["other_hours": "09:00-17:00"]).contains("need other_time_zone"))
        #expect(await harness.failure("find_free_time", ["other_time_zone": "Europe/Paris", "other_hours": "nine to five"]).contains("HH:MM-HH:MM"))
    }

    @Test func freeTimeTextGroupsByDay() {
        let calendar = Calendar.current
        let slots = [DateInterval(start: day(22, 9), end: day(22, 10)), DateInterval(start: day(22, 15), end: day(22, 16)), DateInterval(start: day(23, 9), end: day(23, 11))]
        let text = FreeTime.text(slots, calendar: calendar, locale: Locale(identifier: "en_GB"))
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("09:00–10:00, 15:00–16:00"))
    }

    @Test func busyOnlyExportHidesWhatEventsAre() async throws {
        var settings = Settings()
        settings.fileDirectories = [FileManager.default.temporaryDirectory.path]
        let harness = try Harness(settings: settings)
        let path = harness.folder.appending(path: "busy.ics").path
        let exported = try await harness.call("export_events", ["path": .string(path), "start": "2026-10-19", "end": "2026-10-25", "busy_only": true])
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect((exported["events"] as? Int ?? 0) > 5)
        #expect(!text.contains("Dentist"))
        #expect(!text.contains("Harbour"))
        #expect(!text.contains("ATTENDEE"))
        #expect(!text.contains("Mum's birthday"))  // free all-day events do not make you busy
        #expect(text.contains("SUMMARY:Busy"))
    }

    @Test func invitationExportAsksAttendeesToAnswer() async throws {
        var settings = Settings()
        settings.fileDirectories = [FileManager.default.temporaryDirectory.path]
        let harness = try Harness(settings: settings)
        let dentist = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Dentist" })
        let path = harness.folder.appending(path: "invite.ics").path
        let exported = try await harness.call("export_events", [
            "path": .string(path), "ids": [.string(dentist.id)],
            "invite": ["organizer": "alex@example.com", "organizer_name": "Alex Morgan", "attendees": ["sam@example.com"]],
        ])
        #expect(exported["invitation"] as? Bool == true)
        // Unfolded: long lines continue on the next after a space.
        let text = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "\r\n ", with: "")
        #expect(text.contains("METHOD:REQUEST"))
        #expect(text.contains("ORGANIZER;CN=\"Alex Morgan\":mailto:alex@example.com") || text.contains("ORGANIZER;CN=Alex Morgan:mailto:alex@example.com"))
        #expect(text.contains("RSVP=TRUE:mailto:sam@example.com"))
        #expect(text.contains("SUMMARY:Dentist"))
        #expect(await harness.failure("export_events", [
            "path": .string(path), "ids": [.string(dentist.id)], "invite": ["organizer": "me", "attendees": ["sam@example.com"]],
        ]).contains("not an email address"))
    }
}

@Suite struct DuplicateTests {
    @Test func findsCopiesAndKeepsTheRightOne() async throws {
        let harness = try Harness()
        let thursday = try harness.backend.events(in: day(23), day(24))
        let dentist = try #require(thursday.first { $0.title == "Dentist" })
        let holiday = try #require(thursday.first { $0.title == "Founders' Day" })
        let retro = try #require(thursday.first { $0.title == "Sprint retro" })
        var copy = dentist
        copy.eventID = "COPY-1"
        copy.title = "dentist "
        copy.location = nil
        copy.created = now
        harness.backend.add(copy)
        var personalHoliday = holiday
        personalHoliday.eventID = "COPY-2"
        personalHoliday.calendarID = StandardFixture.personal.id
        personalHoliday.calendarTitle = "Personal"
        harness.backend.add(personalHoliday)
        var retroCopy = retro
        retroCopy.eventID = "COPY-3"
        retroCopy.calendarID = StandardFixture.family.id
        retroCopy.calendarTitle = "Family"
        harness.backend.add(retroCopy)

        let result = try await harness.call("find_duplicates", ["start": "2026-10-19", "end": "2026-10-25"])
        let groups = result["groups"] as? [[String: Any]] ?? []
        #expect(groups.count == 3)
        func group(_ title: String) -> [String: Any]? { groups.first { $0["title"] as? String == title } }
        #expect((group("Dentist")?["keep"] as? [String: Any])?["id"] as? String == dentist.id)
        #expect((group("Founders' Day")?["keep"] as? [String: Any])?["calendar"] as? String == "Holidays")
        let retroRemove = (group("Sprint retro")?["remove"] as? [[String: Any]])?.first
        #expect(retroRemove?["deletable"] as? Bool == false)
        #expect(Set(result["delete_ids"] as? [String] ?? []) == ["COPY-1", "COPY-2"])
    }

    @Test func aRepeatingDuplicateIsReportedOnce() async throws {
        let harness = try Harness()
        let swim = try #require(try harness.backend.events(in: day(22), day(23)).first { $0.title == "Swimming lessons" })
        var copy = try #require(try harness.backend.event(EventRef(eventID: swim.eventID)))
        copy.eventID = "COPY-SWIM"
        copy.occurrenceDate = nil
        harness.backend.add(copy)
        let result = try await harness.call("find_duplicates", ["start": "2026-10-19", "end": "2026-11-15"])
        let groups = result["groups"] as? [[String: Any]] ?? []
        #expect(groups.count == 1)
        #expect((groups.first?["occurrences"] as? Int ?? 0) >= 3)
    }
}
