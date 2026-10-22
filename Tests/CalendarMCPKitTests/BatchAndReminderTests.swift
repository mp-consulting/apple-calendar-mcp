import CalendarFixtures
import CalendarStore
import Foundation
import MCP
import Testing

@testable import CalendarMCPKit

@Suite struct BatchToolTests {
    @Test func createEventsAddsAllAndOneUndoTakesThemBack() async throws {
        let harness = try Harness()
        let result = try await harness.call("create_events", ["events": [
            ["title": "Focus A", "start": "2026-10-26T09:00", "duration_minutes": 90],
            ["title": "Focus B", "start": "2026-10-27T09:00", "duration_minutes": 90, "calendar": "Personal"],
        ]])
        #expect(titles(result["created"]) == ["Focus A", "Focus B"])
        let undoID = try #require(result["undo_id"] as? String)
        let undone = try await harness.call("undo_change", ["change_id": .string(undoID)])
        #expect(undone["count"] as? Int == 2)
        #expect(try harness.backend.events(in: day(26), day(28)).contains { $0.title.hasPrefix("Focus ") } == false)
        #expect(harness.approvals.requests.isEmpty)
        #expect(await harness.failure("undo_change", ["change_id": .string(undoID)]).contains("already undone"))
    }

    @Test func oneBadItemAddsNothing() async throws {
        let harness = try Harness()
        let error = await harness.failure("create_events", ["events": [
            ["title": "Fine", "start": "2026-10-26T09:00"],
            ["title": "Broken", "start": "2026-10-26T09:00", "end": "2026-10-26T08:00"],
        ]])
        #expect(error.contains("events[1]"))
        #expect(try harness.backend.events(in: day(26), day(27)).contains { $0.title == "Fine" } == false)
    }

    @Test func updateEventsAsksOnceForAllSharedEvents() async throws {
        let harness = try Harness()
        let thursday = try harness.backend.events(in: day(23), day(24))
        let retro = try #require(thursday.first { $0.title == "Sprint retro" })
        let dentist = try #require(thursday.first { $0.title == "Dentist" })
        let review = try #require(try harness.backend.events(in: day(20), day(21)).first { $0.title.hasPrefix("Design review") })
        let result = try await harness.call("update_events", ["changes": [
            ["id": .string(retro.id), "start": "2026-10-23T16:00"],
            ["id": .string(review.id), "title": "Design review (v4)"],
            ["id": .string(dentist.id), "location": "14 Harbour Street"],
        ]])
        #expect((result["updated"] as? [Any])?.count == 3)
        #expect(harness.approvals.requests.count == 1)
        #expect(harness.approvals.requests.first?.kind == .notify)
        #expect(harness.approvals.requests.first?.items.count == 3)
        let undoID = try #require(result["undo_id"] as? String)
        _ = try await harness.call("undo_change", ["change_id": .string(undoID)])
        #expect(harness.approvals.requests.count == 2)  // putting shared events back asks once more
        #expect(try harness.backend.event(retro.ref)?.start == retro.start)
        #expect(try harness.backend.event(dentist.ref)?.location == dentist.location)
    }

    @Test func aDeclinedBatchChangesNothing() async throws {
        let harness = try Harness()
        harness.approvals.answer = .denied
        let retro = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Sprint retro" })
        let dentist = try #require(try harness.backend.events(in: day(23), day(24)).first { $0.title == "Dentist" })
        let error = await harness.failure("update_events", ["changes": [
            ["id": .string(dentist.id), "title": "Dentist!"], ["id": .string(retro.id), "title": "Retro!"],
        ]])
        #expect(error.contains("declined"))
        #expect(try harness.backend.event(dentist.ref)?.title == "Dentist")
        #expect(await harness.failure("update_events", ["changes": [
            ["id": .string(dentist.id), "title": "A"], ["id": .string(dentist.id), "title": "B"],
        ]]).contains("twice"))
    }

    @Test func deletingSeveralGivesOneUndoID() async throws {
        let harness = try Harness()
        let thursday = try harness.backend.events(in: day(23), day(24)).filter { ["Dentist", "Sprint retro"].contains($0.title) }
        let result = try await harness.call("delete_event", ["ids": .array(thursday.map { .string($0.id) })])
        #expect(harness.approvals.requests.count == 1)
        let undoID = try #require(result["undo_id"] as? String)
        _ = try await harness.call("undo_change", ["change_id": .string(undoID)])
        #expect(Set(try harness.backend.events(in: day(23), day(24)).map(\.title)).isSuperset(of: ["Dentist", "Sprint retro"]))
    }
}

@Suite struct ReminderToolTests {
    @Test func listsOpenRemindersDueFirstWithOverdue() async throws {
        let harness = try Harness()
        let result = try await harness.call("list_reminders")
        let reminders = result["reminders"] as? [[String: Any]] ?? []
        #expect(reminders.map { $0["title"] as? String } == [
            "Book flights to Lisbon", "Send Northwind the pricing proposal", "Review Chloé's onboarding notes", "Buy a present for Mum",
            "Renew passport",
        ])
        #expect(reminders.first?["overdue"] as? Bool == true)
        #expect(reminders.first?["priority"] as? String == "high")
        #expect(reminders[1]["overdue"] == nil)
        #expect(titles(result["lists"]) == ["Reminders", "Errands"])
        let due = try await harness.call("list_reminders", ["due_before": "2026-10-22"])
        #expect((due["reminders"] as? [Any])?.count == 3)
        let done = try await harness.call("list_reminders", ["status": "completed"])
        #expect(titles(done["reminders"]) == ["Expense report for September"])
        let errands = try await harness.call("list_reminders", ["lists": ["Errands"]])
        #expect(titles(errands["reminders"]) == ["Buy a present for Mum", "Renew passport"])
    }

    @Test func agendaShowsRemindersDue() async throws {
        let harness = try Harness()
        let agenda = try await harness.call("agenda")
        #expect(titles(agenda["reminders_due"]) == ["Book flights to Lisbon", "Send Northwind the pricing proposal"])
        harness.backend.setReminderAccess(.notDetermined)
        #expect(try await harness.call("agenda")["reminders_due"] == nil)
        #expect(await harness.failure("list_reminders").contains("Reminders"))
    }

    @Test func createCompleteAndUndo() async throws {
        let harness = try Harness()
        let created = try await harness.call("create_reminder", ["title": "Call the bank", "due": "2026-10-22T11:00", "list": "Errands", "priority": "medium"])
        let reminder = try #require(created["created"] as? [String: Any])
        #expect(reminder["list"] as? String == "Errands")
        #expect(reminder["due"] as? String == Render.isoDate(day(22, 11)))
        let id = try #require(reminder["id"] as? String)
        let done = try await harness.call("update_reminder", ["id": .string(id), "completed": true])
        #expect((done["updated"] as? [String: Any])?["completed"] != nil)
        let undoID = try #require(done["undo_id"] as? String)
        _ = try await harness.call("undo_change", ["change_id": .string(undoID)])
        #expect(try harness.backend.reminder(id)?.isCompleted == false)
        let moved = try await harness.call("update_reminder", ["id": .string(id), "due": ""])
        #expect((moved["updated"] as? [String: Any])?["due"] == nil)
    }

    @Test func deletingAsksAndUndoBringsItBack() async throws {
        let harness = try Harness()
        let result = try await harness.call("delete_reminders", ["ids": ["DEMO-R5"]])
        #expect(titles(result["deleted"]) == ["Renew passport"])
        #expect(harness.approvals.requests.map(\.kind) == [.delete])
        #expect(try harness.backend.reminder("DEMO-R5") == nil)
        let undoID = try #require(result["undo_id"] as? String)
        _ = try await harness.call("undo_change", ["change_id": .string(undoID)])
        let back = try harness.backend.reminders(ReminderQuery(listIDs: [StandardFixture.errands.id]))
        #expect(back.contains { $0.title == "Renew passport" })
    }

    @Test func readOnlyAndHiddenListsAreRespected() async throws {
        var settings = Settings()
        settings.setAccess(StandardFixture.errands.id, .read)
        let harness = try Harness(settings: settings)
        #expect(await harness.failure("create_reminder", ["title": "X", "list": "Errands"]).contains("only read"))
        #expect(await harness.failure("update_reminder", ["id": "DEMO-R5", "completed": true]).contains("only read"))
        var hidden = Settings()
        hidden.setAccess(StandardFixture.errands.id, .hidden)
        let other = try Harness(settings: hidden)
        #expect(titles(try await other.call("list_reminders")["reminders"]).contains("Renew passport") == false)
        #expect(await other.failure("update_reminder", ["id": "DEMO-R5", "title": "Y"]).contains("No reminder"))
    }
}
