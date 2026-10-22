import CalendarStore
import Foundation
import MCP

public typealias MCPValue = MCP.Value

/// Environment checks shared by `apple-calendar-mcp doctor` and the menu bar app.
public enum Doctor {
    public struct Check: Sendable, Identifiable {
        public enum State: Sendable { case ok, warning, failed }
        public var id: String { name }
        public var name: String
        public var state: State
        public var detail: String
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    public static func checks(settings: Settings, socket: URL = SharedPaths.bridgeSocket) async -> [Check] {
        var checks: [Check] = []
        let here = EventKitBackend.authorization()
        checks.append(Check(
            name: "This process", state: .ok,
            detail: here == .granted ? "has Calendars access: servers started here read calendars directly"
                : "no Calendars access of its own (\(EventKitBackend.explain(here))); servers go through the app"))

        switch Result(catching: { try PeerRequirement.matchingSelf() }) {
        case .failure(let error):
            checks.append(Check(name: "Bridge", state: here == .granted ? .warning : .failed, detail: "\(error)"))
        case .success(let requirement):
            let client = BridgeClient(socket: socket, requirement: requirement, launcher: nil)
            if client.isAppRunning, let (info, access) = try? client.hello() {
                checks.append(Check(name: "Menu bar app", state: .ok, detail: "running, version \(info.version) (pid \(info.pid))"))
                checks.append(Check(
                    name: "Calendar access", state: access == .granted ? .ok : .failed,
                    detail: access == .granted ? "granted to the app" : EventKitBackend.explain(access)))
                if access == .granted, let calendars = try? BridgeBackend(client: client).calendars() {
                    let hidden = calendars.count - settings.visible(calendars).count
                    checks.append(Check(
                        name: "Calendars", state: calendars.isEmpty ? .warning : .ok,
                        detail: "\(calendars.count) in \(Set(calendars.map(\.account)).count) accounts"
                            + (hidden == 0 ? "" : ", \(hidden) hidden from Claude")))
                }
                let reminders = BridgeBackend(client: client).reminderAccess()
                checks.append(Check(
                    name: "Reminders access", state: reminders == .granted ? .ok : .warning,
                    detail: reminders == .granted ? "granted to the app" : "optional: " + EventKitBackend.explainReminders(reminders)))
            } else {
                let installed = LaunchContext.appURL()
                checks.append(Check(
                    name: "Menu bar app", state: here == .granted ? .warning : .failed,
                    detail: installed.map { "not running (\($0.path)); servers open it when they need it" }
                        ?? "not installed: it holds the Calendars permission (see the README)"))
            }
        }

        // The last day only: a server that died long ago is history, not a problem to fix.
        let stuck = ActivityLog().stuck().filter { Date().timeIntervalSince($0.date) < 86_400 }
        if !stuck.isEmpty {
            let lines = stuck.prefix(5).map { entry in
                let alive = kill(entry.pid, 0) == 0 ? "still running" : "server gone"
                return "\(entry.tool) since \(Render.isoDate(entry.date)) (pid \(entry.pid), \(alive))"
            }
            checks.append(Check(
                name: "Unfinished calls", state: .warning,
                detail: "\(stuck.count) started over 2 minutes ago and never finished: " + lines.joined(separator: "; ")))
        }
        checks.append(contentsOf: clientChecks(ActivityLog().recent(limit: 400)))
        checks.append(Check(
            name: "Settings", state: .ok,
            detail: "changes \(settings.allowCalendarChanges ? "allowed" : "off"), delete policy \(settings.deletePolicy.rawValue), "
                + "shared events \(settings.sharedEventPolicy.rawValue), batch limit \(settings.maxBatchSize), "
                + "working hours \(settings.workdayStart)–\(settings.workdayEnd)"))
        return checks
    }

    /// The server build each client used last (from the activity log), and a warning when one used an older server
    /// than this one in the last hour.
    static func clientChecks(_ entries: [ActivityEntry], current: String = CalendarMCPVersion.current, now: Date = Date()) -> [Check] {
        let week = entries.filter { now.timeIntervalSince($0.date) < 7 * 86_400 }
        let versions = ActivityEntry.serverVersions(in: week)
        guard !versions.isEmpty else { return [] }
        var checks = [Check(
            name: "Clients", state: .ok,
            detail: versions.map { "\($0.client): \($0.version ?? "unknown") (\(Render.isoDate($0.date)))" }.joined(separator: "; "))]
        let older = ActivityEntry.clientsOnOlderServer(in: week, current: current, now: now)
        if !older.isEmpty {
            checks.append(Check(
                name: "Older server", state: .warning,
                detail: older.map { "\($0.client) ran \($0.version ?? "an older version")" }.joined(separator: ", ")
                    + " in the last hour, older than \(current). Restart it, and check which server it starts."))
        }
        return checks
    }

    public static func report(settings: Settings) async -> String {
        await checks(settings: settings).map { check -> String in
            let mark = switch check.state {
            case .ok: "✓"
            case .warning: "!"
            case .failed: "✗"
            }
            return "\(mark) \(check.name): \(check.detail)"
        }.joined(separator: "\n")
    }
}
