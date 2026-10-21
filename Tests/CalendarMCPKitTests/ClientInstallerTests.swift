import Foundation
import Testing

@testable import CalendarMCPKit

@Suite("Claude client installer")
struct ClientInstallerTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
    var desktopConfig: URL { home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json") }

    func installer() -> ClientInstaller {
        // A non-existent CLI path forces the JSON route for Claude Code.
        ClientInstaller(serverPath: "/Applications/Apple Calendar MCP.app/Contents/Helpers/apple-calendar-mcp", home: home,
                        claudeCLI: "/nonexistent/claude")
    }

    /// The Claude app saves its preferences in the same file, so only our own changes may ask for a restart.
    @Test func recordsOnlyItsOwnChangesToTheClaudeAppConfig() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"preferences":{"sidebarMode":"chat"}}"#.utf8).write(to: desktopConfig)
        #expect(installer().desktopEntryChanged == nil)

        try installer().install(.claudeCode)
        #expect(installer().desktopEntryChanged == nil)

        let before = Date.now.addingTimeInterval(-1)
        try installer().install(.claudeDesktop)
        let added = try #require(installer().desktopEntryChanged)
        #expect(added >= before)

        try Data(#"{"preferences":{"sidebarMode":"code"},"mcpServers":{}}"#.utf8).write(to: desktopConfig)
        #expect(installer().desktopEntryChanged == added)
    }
}
