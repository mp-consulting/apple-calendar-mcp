import AppKit
import CalendarFixtures
import CalendarMCPKit
import CalendarStore
import Foundation

let usage = """
    apple-calendar-mcp \(CalendarMCPVersion.current): an MCP server for Apple Calendar.

    USAGE
      apple-calendar-mcp [--read-only] [--demo]
          Serve MCP over stdio (what MCP clients run).
      apple-calendar-mcp doctor
          Check the menu bar app, the Calendars permission and the bridge.
      apple-calendar-mcp install [claude-code | claude-desktop | all]
          Register this server with Claude Code and/or Claude Desktop (default: all found).
      apple-calendar-mcp uninstall [claude-code | claude-desktop | all]
          Remove it again.
      apple-calendar-mcp skills [list | install [NAME]... | uninstall [NAME]... | export DIR]
          Manage the Claude skills that ship with the server (~/.claude/skills).
      apple-calendar-mcp call <tool> ['{"json":"arguments"}']
          Run one tool and print its result (for scripts and debugging).

    OPTIONS
      --read-only  Only reading tools: no creating, changing or deleting events.
      --demo       A made-up week in memory instead of your calendars (screenshots, trying the tools).

    Settings shared with the menu bar app live in \(SharedPaths.settings.path).
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Exits when the parent (the MCP client) dies, so no orphan keeps a connection to the app.
func watchParent() {
    let parent = getppid()
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 5)
            if getppid() != parent { exit(0) }
        }
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var readOnly = false
var demo = false
var command: String?
var rest: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--read-only": readOnly = true
    case "--demo": demo = true
    case "-h", "--help", "help":
        print(usage)
        exit(0)
    case "--version":
        print(CalendarMCPVersion.current)
        exit(0)
    default:
        if command == nil, !argument.hasPrefix("-") { command = argument } else { rest.append(argument) }
    }
}
// The Claude app extension passes its "Read-only" setting this way.
if let flag = ProcessInfo.processInfo.environment["APPLE_CALENDAR_MCP_READ_ONLY"]?.lowercased(), ["true", "1", "yes"].contains(flag) {
    readOnly = true
}
let isReadOnly = readOnly
let settings = SettingsProvider { settings in
    if isReadOnly { settings.allowCalendarChanges = false }
}

func makeToolbox(demo isDemo: Bool, readOnly: Bool, settings: SettingsProvider) -> CalendarToolbox {
    let approveAll: Approver = { @Sendable _, _ in .approved }
    let approver: Approver = isDemo ? approveAll : LaunchContext.approver()
    let toolbox = CalendarToolbox(
        backend: { isDemo ? StandardFixture.backend() : try LaunchContext.backend() }, settings: settings,
        // Benchmarks, demos and scripted runs set this so they don't show up in the menu bar's Activity.
        activity: ProcessInfo.processInfo.environment["APPLE_CALENDAR_MCP_NO_ACTIVITY"] == nil && !isDemo ? ActivityLog() : nil,
        journal: isDemo ? nil : ChangeJournal(),
        approver: approver, readOnly: readOnly)
    toolbox.open = { url in NSWorkspace.shared.open(url) }
    return toolbox
}

switch command {
case nil, "serve":
    watchParent()
    try await CalendarMCPServer.runStdio(toolbox: makeToolbox(demo: demo, readOnly: readOnly, settings: settings))

case "doctor":
    print(await Doctor.report(settings: settings.current))

case "install", "uninstall":
    let me = URL(filePath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    let installer = ClientInstaller(serverPath: me)
    let target = rest.first ?? "all"
    let clients = target == "all" ? ClientInstaller.Client.allCases : ClientInstaller.Client.allCases.filter { $0.rawValue == target }
    guard !clients.isEmpty else { fail("usage: apple-calendar-mcp \(command!) [claude-code | claude-desktop | all]") }
    for client in clients {
        if installer.status(client) == .clientMissing, target == "all" {
            print("\(client.displayName): not found, skipped")
            continue
        }
        do {
            if command == "install" {
                print("\(client.displayName): \(try installer.install(client))")
            } else {
                try installer.uninstall(client)
                print("\(client.displayName): removed")
            }
        } catch {
            print("\(client.displayName): \(error)")
        }
    }

case "tools-json":
    // Tool names and one-line descriptions, for the .mcpb manifest (see Scripts/make-mcpb.sh).
    let toolbox = CalendarToolbox(backend: { throw ToolError("not needed") }, settings: settings, activity: nil)
    let tools: [[String: String]] = toolbox.definitions.map { definition in
        let text = definition.tool.description ?? ""
        let first = text.firstIndex(of: ".").map { String(text[...$0]) } ?? text
        return ["name": definition.tool.name, "description": first.replacingOccurrences(of: "\n", with: " ")]
    }
    let data = try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))

case "skills":
    let installer = SkillInstaller()
    let action = rest.first ?? "list"
    let names = Set(rest.dropFirst())
    let selected = names.isEmpty ? SkillCatalog.all : SkillCatalog.all.filter { names.contains($0.name) }
    if !names.isEmpty, selected.count != names.count {
        fail("unknown skill; available: \(SkillCatalog.all.map(\.name).joined(separator: ", "))")
    }
    switch action {
    case "list":
        for skill in SkillCatalog.all {
            print("\(skill.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(installer.state(of: skill).rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(skill.summary)")
        }
    case "install":
        let done = try installer.install(selected)
        print("installed \(done.map(\.name).joined(separator: ", ")) into \(installer.directory.path)")
        let skipped = selected.filter { installer.state(of: $0) == .foreign }
        if !skipped.isEmpty { print("skipped (a different skill with that name exists): \(skipped.map(\.name).joined(separator: ", "))") }
    case "uninstall":
        let removed = try installer.uninstall(selected)
        print("removed \(removed.isEmpty ? "nothing" : removed.map(\.name).joined(separator: ", "))")
    case "export":
        guard rest.count >= 2 else { fail("usage: apple-calendar-mcp skills export DIR") }
        let zips = try SkillInstaller.exportZips(SkillCatalog.all, to: URL(filePath: (rest[1] as NSString).expandingTildeInPath))
        for zip in zips { print(zip.path) }
    default:
        fail("usage: apple-calendar-mcp skills [list | install [NAME]... | uninstall [NAME]... | export DIR]")
    }

case "call":
    guard let tool = rest.first else { fail("usage: apple-calendar-mcp call <tool> [json]") }
    var parsed: [String: MCPValue]?
    if rest.count > 1 {
        guard let data = rest[1].data(using: .utf8), let value = try? JSONDecoder().decode([String: MCPValue].self, from: data) else {
            fail("arguments must be a JSON object")
        }
        parsed = value
    }
    let toolbox = makeToolbox(demo: demo, readOnly: readOnly, settings: settings)
    let result = await toolbox.call(tool, arguments: parsed)
    toolbox.activity?.flush()
    for content in result.content {
        if case .text(let text, _, _) = content { print(text) }
    }
    exit(result.isError == true ? 1 : 0)

default:
    fail("unknown command \(command!)\n\n\(usage)")
}
