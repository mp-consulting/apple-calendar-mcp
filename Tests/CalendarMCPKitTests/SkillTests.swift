import Foundation
import Testing

@testable import CalendarMCPKit

@Suite struct SkillTests {
    static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func everySkillIsEmbeddedAndCurrent() throws {
        let folder = Self.repository.appending(path: "Skills")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == SkillCatalog.all.map(\.name).sorted())
        for skill in SkillCatalog.all {
            let onDisk = try String(contentsOf: folder.appending(path: "\(skill.name)/SKILL.md"), encoding: .utf8)
            #expect(onDisk + "\n" == skill.content || onDisk == skill.content, "run Scripts/embed-skills.sh (\(skill.name))")
            #expect(skill.content.contains(SkillCatalog.marker))
            #expect(SkillCatalog.blurbs[skill.name] != nil)
        }
    }

    /// Words in backticks that look like tool or parameter names (snake_case) must exist.
    @Test func skillsOnlyReferenceRealToolsAndParameters() throws {
        let toolbox = CalendarToolbox(backend: { throw ToolError("unused") }, activity: nil)
        var known = Set(toolbox.definitions.map(\.tool.name))
        for definition in toolbox.definitions {
            guard case .object(let schema) = definition.tool.inputSchema, case .object(let properties)? = schema["properties"] else { continue }
            known.formUnion(properties.keys)
            for case .object(let nested) in properties.values {
                if case .object(let inner)? = nested["properties"] { known.formUnion(inner.keys) }
            }
        }
        // Keys of tool results that skills point at.
        known.formUnion(["conflicts", "free", "pending_invitations", "reminders_due", "undo_id", "undo_ids", "change_id", "delete_ids"])
        // Apple Mail MCP's tools, for skills that hand an email to it when it is connected.
        known.formUnion(["compose_email", "search_messages", "get_message"])
        let pattern = /`([a-z]+(?:_[a-z]+)+)`/
        for skill in SkillCatalog.all {
            for match in skill.content.matches(of: pattern) {
                let word = String(match.output.1)
                #expect(known.contains(word), "\(skill.name) mentions `\(word)`, which is no tool or parameter")
            }
        }
    }
}
