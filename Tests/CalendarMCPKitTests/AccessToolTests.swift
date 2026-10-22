import CalendarFixtures
import CalendarStore
import Foundation
import MCP
import Testing

@testable import CalendarMCPKit

@Suite struct CalendarAccessTests {
    func readOnlyPersonal() throws -> Harness {
        var settings = Settings()
        settings.setAccess(StandardFixture.personal.id, .read)
        return try Harness(settings: settings)
    }

    @Test func aReadOnlyCalendarIsListedReadOnlyAndStillRead() async throws {
        let harness = try readOnlyPersonal()
        let calendars = try await harness.call("list_calendars")
        let personal = (calendars["calendars"] as? [[String: Any]])?.first { $0["title"] as? String == "Personal" }
        #expect(personal?["read_only"] as? Bool == true)
        let week = try await harness.call("list_events", ["start": "2026-10-19", "end": "2026-10-25"])
        #expect(titles(week["events"]).contains("Dentist"))
    }

    @Test func nothingInAReadOnlyCalendarChanges() async throws {
        let harness = try readOnlyPersonal()
        let dentist = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Dentist" })
        #expect(await harness.failure("create_event", ["title": "X", "start": "2026-10-23T09:00", "calendar": "Personal"]).contains("only read"))
        #expect(await harness.failure("update_event", ["id": .string(dentist.id), "title": "Y"]).contains("only read"))
        #expect(await harness.failure("delete_event", ["ids": [.string(dentist.id)]]).contains("Nothing was deleted"))
        // Moving an event into it is refused too.
        let retro = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Sprint retro" })
        #expect(await harness.failure("update_event", ["id": .string(retro.id), "calendar": "Personal"]).contains("only read"))
        #expect(try harness.backend.event(dentist.ref)?.title == "Dentist")
        #expect(harness.approvals.requests.isEmpty)
    }

    @Test func accessSettingsRoundTrip() throws {
        var settings = Settings()
        settings.setAccess("a", .read)
        #expect(settings.access("a") == .read)
        settings.setAccess("a", .hidden)
        #expect(settings.access("a") == .hidden && !settings.isReadOnly("a"))
        settings.setAccess("a", .change)
        #expect(settings.access("a") == .change && settings.hiddenCalendars.isEmpty && settings.readOnlyCalendars.isEmpty)
        let data = try JSONEncoder().encode({ var s = Settings(); s.readOnlyCalendars = ["x"]; return s }())
        #expect(try JSONDecoder().decode(Settings.self, from: data).readOnlyCalendars == ["x"])
    }
}
