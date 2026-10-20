import CalendarFixtures
import CalendarStore
import Foundation
import MCP
import Testing

@testable import CalendarMCPKit

/// Wednesday 21 October 2026, 10:15, in the Mac's time zone: the fixture's week starts on Monday the 19th.
let now: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10, minute: 15))!

func day(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

/// What the approver was asked, and what it answers.
final class ApprovalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ApprovalRequest] = []
    var answer: ApprovalDecision = .approved

    var requests: [ApprovalRequest] { lock.withLock { _requests } }

    func record(_ request: ApprovalRequest) -> ApprovalDecision {
        lock.withLock { _requests.append(request) }
        return answer
    }
}

struct Harness {
    let backend: MemoryBackend
    let toolbox: CalendarToolbox
    let approvals = ApprovalLog()
    let folder: URL
    let settingsURL: URL

    init(settings: Settings = Settings(), readOnly: Bool = false) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "acm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        settingsURL = folder.appending(path: "settings.json")
        try settings.save(to: settingsURL)
        let backend = StandardFixture.backend(now: now)
        self.backend = backend
        let approvals = self.approvals
        toolbox = CalendarToolbox(
            backend: { backend }, settings: SettingsProvider(url: settingsURL), activity: nil,
            journal: ChangeJournal(url: folder.appending(path: "changes.json")),
            approver: { request, _ in approvals.record(request) }, readOnly: readOnly)
        toolbox.now = { now }
        toolbox.clientName = "tests"
    }

    /// The tool's JSON result; fails the test on a tool error.
    func call(_ name: String, _ arguments: [String: Value] = [:], sourceLocation: SourceLocation = #_sourceLocation) async throws -> [String: Any] {
        let result = await toolbox.call(name, arguments: arguments)
        guard case .text(let text, _, _)? = result.content.first else { throw ToolError("no text") }
        if result.isError == true {
            Issue.record("\(name) failed: \(text)", sourceLocation: sourceLocation)
            throw ToolError(text)
        }
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    /// The error text of a call that must fail.
    func failure(_ name: String, _ arguments: [String: Value] = [:]) async -> String {
        let result = await toolbox.call(name, arguments: arguments)
        guard result.isError == true, case .text(let text, _, _)? = result.content.first else { return "(no error)" }
        return text
    }
}

func titles(_ list: Any?) -> [String] { (list as? [[String: Any]] ?? []).compactMap { $0["title"] as? String } }

@Suite struct ReadToolTests {
    @Test func agendaShowsNextConflictsAndFreeTime() async throws {
        let harness = try Harness()
        let agenda = try await harness.call("agenda")
        #expect(titles(agenda["events"]) == ["Team standup", "Customer call: Fabrikam", "Engineering sync", "Lunch with Ben"])
        #expect(titles(agenda["now"]) == ["Customer call: Fabrikam"])
        #expect((agenda["next"] as? [String: Any])?["title"] as? String == "Engineering sync")
        let conflicts = agenda["conflicts"] as? [[String: Any]] ?? []
        #expect(conflicts.count == 1)
        #expect(conflicts.first?["overlap_minutes"] as? Int == 30)
        // Free time starts after the conflict, within working hours.
        let free = agenda["free"] as? [[String: Any]] ?? []
        #expect(free.first?["start"] as? String == Render.isoDate(day(21, 11, 15)))
        #expect(free.last?["end"] as? String == Render.isoDate(day(21, 18)))
    }

    @Test func listEventsExpandsRepeatsAndHidesCalendars() async throws {
        var settings = Settings()
        settings.hiddenCalendars = [StandardFixture.family.id]
        let harness = try Harness(settings: settings)
        let week = try await harness.call("list_events", ["start": "2026-10-19", "end": "2026-10-23"])
        let names = titles(week["events"])
        #expect(names.filter { $0 == "Team standup" }.count == 5)
        #expect(!names.contains("Swimming lessons"))
        #expect(!names.contains("Mum's birthday"))
        let calendars = try await harness.call("list_calendars")
        #expect(titles(calendars["calendars"]) == ["Work", "Personal", "Holidays"])
        #expect(calendars["hidden"] as? Int == 1)
    }

    @Test func searchByWordsPersonAndGroups() async throws {
        let harness = try Harness()
        let byWord = try await harness.call("search_events", ["query": "northwind"])
        // The title of one, the notes of the other.
        #expect(titles(byWord["events"]) == ["Focus: pricing proposal", "Quarterly planning with Northwind"])
        let byTitle = try await harness.call("search_events", ["title": "northwind"])
        #expect(titles(byTitle["events"]) == ["Quarterly planning with Northwind"])
        let byPerson = try await harness.call("search_events", ["person": "chloe", "start": "2026-10-19", "end": "2026-10-25"])
        #expect(Set(titles(byPerson["events"])) == ["Design review: onboarding", "Sprint retro"])
        let video = try await harness.call("search_events", ["has_video": true, "start": "2026-10-19", "end": "2026-10-25"])
        #expect(titles(video["events"]).contains("Design review: onboarding"))
        let pending = try await harness.call("pending_invitations")
        #expect(titles(pending["invitations"]) == ["Quarterly planning with Northwind"])
        let grouped = try await harness.call("search_events", ["start": "2026-10-19", "end": "2026-10-25", "group_by": "calendar"])
        let groups = grouped["groups"] as? [[String: Any]] ?? []
        #expect(groups.first?["name"] as? String == "Work")
    }

    @Test func freeTimeHonoursHoursBufferAndLength() async throws {
        let harness = try Harness()
        let result = try await harness.call("find_free_time", [
            "start": "2026-10-22", "end": "2026-10-22", "duration_minutes": 90, "buffer_minutes": 15, "earliest": "10:00",
        ])
        let slots = result["slots"] as? [[String: Any]] ?? []
        // Thursday: standup 9:30–9:45, Northwind 14:00–15:30, swimming after hours.
        #expect(slots.map { $0["start"] as? String } == [Render.isoDate(day(22, 10)), Render.isoDate(day(22, 15, 45))])
        #expect(slots.first?["end"] as? String == Render.isoDate(day(22, 13, 45)))
    }

    @Test func getEventShowsAttendeesAndLink() async throws {
        let harness = try Harness()
        let search = try await harness.call("search_events", ["query": "design review"])
        let id = try #require((search["events"] as? [[String: Any]])?.first?["id"] as? String)
        let event = try await harness.call("get_event", ["id": .string(id)])
        let people = event["attendees"] as? [[String: Any]] ?? []
        #expect(people.count == 5)
        #expect(people.contains { $0["status"] as? String == "declined" })
        #expect((event["link"] as? String)?.hasPrefix("ical://ekevent/") == true)
        #expect((event["video"] as? String)?.contains("zoom.us") == true)
    }

    @Test func statisticsCountMeetings() async throws {
        let harness = try Harness()
        let stats = try await harness.call("calendar_statistics", ["start": "2026-10-19", "end": "2026-10-23"])
        #expect((stats["meetings"] as? Int ?? 0) >= 10)
        #expect((stats["by_person"] as? [[String: Any]])?.first?["name"] as? String == "Anna Berg")
    }

    @Test func badArgumentsAreToolErrors() async throws {
        let harness = try Harness()
        #expect(await harness.failure("list_events", ["start": "next tuesday"]).contains("must be YYYY-MM-DD"))
        #expect(await harness.failure("get_event", ["id": "nope"]).contains("No event"))
        #expect(await harness.failure("search_events", ["calendars": ["Nope"]]).contains("No calendar"))
        #expect(await harness.failure("agenda", ["time_zone": "Mars/Olympus"]).contains("not a time zone"))
    }
}

@Suite struct ChangeToolTests {
    @Test func createTimedAndAllDayEvents() async throws {
        let harness = try Harness()
        let created = try await harness.call("create_event", ["title": "Haircut", "start": "2026-10-23T17:00", "alarms": [30]])
        let event = try #require(created["created"] as? [String: Any])
        #expect(event["end"] as? String == Render.isoDate(day(23, 18)))
        #expect(event["calendar"] as? String == "Work")
        let trip = try await harness.call("create_event", ["title": "Trip", "start": "2026-11-02", "end": "2026-11-04", "calendar": "Personal"])
        let made = try #require(trip["created"] as? [String: Any])
        #expect(made["all_day"] as? Bool == true)
        #expect(made["date"] as? String == "2026-11-02")
        #expect(made["end_date"] as? String == "2026-11-04")
        #expect(harness.approvals.requests.isEmpty)
    }

    @Test func dryRunChangesNothing() async throws {
        let harness = try Harness()
        let before = try harness.backend.events(in: day(19), day(26)).count
        let preview = try await harness.call("create_event", ["title": "X", "start": "2026-10-23T09:00", "dry_run": true])
        #expect(preview["dry_run"] as? Bool == true)
        #expect(try harness.backend.events(in: day(19), day(26)).count == before)
    }

    @Test func readOnlyCalendarsAndSwitchesAreRespected() async throws {
        let harness = try Harness()
        #expect(await harness.failure("create_event", ["title": "X", "start": "2026-10-23T09:00", "calendar": "Holidays"]).contains("read-only"))
        var off = Settings()
        off.allowCalendarChanges = false
        let locked = try Harness(settings: off)
        #expect(await locked.failure("create_event", ["title": "X", "start": "2026-10-23T09:00"]).contains("turned off"))
        let readOnly = try Harness(readOnly: true)
        #expect(!readOnly.toolbox.listedDefinitions.contains { $0.kind == .change })
    }

    @Test func movingAnEventKeepsItsLength() async throws {
        let harness = try Harness()
        let dentist = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Dentist" })
        let moved = try await harness.call("update_event", ["id": .string(dentist.id), "start": "2026-10-23T08:30"])
        let event = try #require(moved["updated"] as? [String: Any])
        #expect(event["end"] as? String == Render.isoDate(day(23, 9, 15)))
        #expect((moved["changed"] as? String)?.hasPrefix("Moves to") == true)
        #expect(harness.approvals.requests.isEmpty)  // no one else is invited
    }

    @Test func sharedEventsAskFirstAndADeclineChangesNothing() async throws {
        let harness = try Harness()
        let review = try #require(try harness.backend.events(in: day(20), day(21)).first { $0.title.hasPrefix("Design review") })
        harness.approvals.answer = .denied
        let error = await harness.failure("update_event", ["id": .string(review.id), "start": "2026-10-20T15:00"])
        #expect(error.contains("declined"))
        #expect(harness.approvals.requests.first?.kind == .notify)
        #expect(harness.approvals.requests.first?.attendees.contains { $0.contains("Chloé Martin") } == true)
        #expect(try harness.backend.event(review.ref)?.start == review.start)
    }

    @Test func oneOccurrenceOfARepeatingEvent() async throws {
        let harness = try Harness()
        let thursday = try #require(try harness.backend.events(in: day(22), day(23)).first { $0.title == "Team standup" })
        #expect(thursday.id.contains("#"))
        _ = try await harness.call("update_event", ["id": .string(thursday.id), "title": "Standup (short)", "span": "this"])
        let week = try harness.backend.events(in: day(19), day(24)).filter { $0.title.hasPrefix("Standup") || $0.title == "Team standup" }
        #expect(week.filter { $0.title == "Standup (short)" }.count == 1)
        #expect(week.filter { $0.title == "Team standup" }.count == 4)
        #expect(await harness.failure("update_event", ["id": .string(thursday.id), "repeat": ["frequency": "daily"]]).contains("span"))
    }

    @Test func deleteAsksAndUndoBringsItBack() async throws {
        let harness = try Harness()
        let dentist = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Dentist" })
        let result = try await harness.call("delete_event", ["ids": [.string(dentist.id)]])
        #expect(titles(result["deleted"]) == ["Dentist"])
        #expect(harness.approvals.requests.map(\.kind) == [.delete])
        #expect(try harness.backend.event(dentist.ref) == nil)
        let undoID = try #require((result["undo_ids"] as? [String])?.first)
        let undone = try await harness.call("undo_change", ["change_id": .string(undoID)])
        #expect(undone["undone"] as? String == "deleted")
        let back = try harness.backend.events(in: day(23), day(24)).first { $0.title == "Dentist" }
        #expect(back?.start == dentist.start)
        #expect(back?.location == dentist.location)
        #expect(await harness.failure("undo_change", ["change_id": .string(undoID)]).contains("already undone"))
    }

    @Test func neverDeleteMeansNever() async throws {
        var settings = Settings()
        settings.deletePolicy = .never
        let harness = try Harness(settings: settings)
        let dentist = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Dentist" })
        #expect(await harness.failure("delete_event", ["ids": [.string(dentist.id)]]).contains("turned off"))
        #expect(try harness.backend.event(dentist.ref) != nil)
    }

    @Test func undoListAndUndoOfACreate() async throws {
        let harness = try Harness()
        _ = try await harness.call("create_event", ["title": "Temp", "start": "2026-10-23T11:00"])
        let list = try await harness.call("undo_change")
        let changes = list["changes"] as? [[String: Any]] ?? []
        #expect(changes.count == 1)
        let id = try #require(changes.first?["change_id"] as? String)
        _ = try await harness.call("undo_change", ["change_id": .string(id)])
        #expect(try harness.backend.events(in: day(23), day(24)).contains { $0.title == "Temp" } == false)
        #expect(harness.approvals.requests.isEmpty)  // its own untouched event goes without asking
    }

    @Test func batchLimit() async throws {
        var settings = Settings()
        settings.maxBatchSize = 1
        let harness = try Harness(settings: settings)
        #expect(await harness.failure("delete_event", ["ids": ["DEMO-1", "DEMO-2"]]).contains("Too many"))
    }
}

@Suite struct FileToolTests {
    @Test func exportThenImportICS() async throws {
        var settings = Settings()
        settings.fileDirectories = [FileManager.default.temporaryDirectory.path]
        let harness = try Harness(settings: settings)
        let path = harness.folder.appending(path: "week.ics").path
        let exported = try await harness.call("export_events", ["path": .string(path), "start": "2026-10-19", "end": "2026-10-25", "query": "quarterly"])
        #expect(exported["events"] as? Int == 1)
        let preview = try await harness.call("import_ics", ["path": .string(path), "dry_run": true])
        #expect(titles(preview["events"]) == ["Quarterly planning with Northwind"])
        // Already there (same UID): skipped.
        let again = try await harness.call("import_ics", ["path": .string(path)])
        #expect(titles(again["created"]).isEmpty)
        #expect((again["skipped"] as? [[String: Any]])?.count == 1)
        // Outside the allowed folders: refused.
        #expect(await harness.failure("export_events", ["path": "/tmp/acm-outside.ics"]).contains("outside the allowed folders"))
        #expect(await harness.failure("import_ics", ["path": .string(harness.folder.appending(path: "settings.json").path)]).contains("Only .ics"))
    }

    @Test func csvExportNeutralizesFormulas() {
        var event = Event(eventID: "x", calendarID: "c", calendarTitle: "Work", title: "=HYPERLINK(\"http://x\")", start: now, end: now)
        event.notes = "line 1\nline 2"
        let csv = CalendarToolbox.csv([event])
        #expect(csv.contains("\"'=HYPERLINK(\"\"http://x\"\")\""))
        #expect(csv.contains("line 1 line 2"))
    }
}

@Suite struct DefinitionTests {
    @Test func everyRequiredArgumentIsAProperty() throws {
        let harness = try Harness()
        for definition in harness.toolbox.definitions {
            guard case .object(let schema) = definition.tool.inputSchema, case .object(let properties)? = schema["properties"] else {
                Issue.record("\(definition.tool.name) has no properties")
                continue
            }
            if case .array(let required)? = schema["required"] {
                for name in required.compactMap(\.stringValue) {
                    #expect(properties[name] != nil, "\(definition.tool.name).\(name)")
                }
            }
        }
    }

    @Test func toolNamesAreUnique() throws {
        let names = try Harness().toolbox.definitions.map(\.tool.name)
        #expect(Set(names).count == names.count)
    }
}
