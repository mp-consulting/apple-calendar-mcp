import AppKit
import CalendarMCPKit
import CalendarStore
import SwiftUI

/// Where the Claude tab adds skills.
enum SkillTarget: Hashable {
    case claudeCode
    case claudeApp

    var explanation: String {
        switch self {
        case .claudeCode: "Installs into ~/.claude/skills. New Claude Code sessions use them."
        case .claudeApp: "Saves one .zip per skill to upload in Claude › Settings › Capabilities › Skills."
        }
    }
}

/// Something the user has to fix, shown as a row only while it is wrong.
struct AttentionItem: Identifiable, Hashable {
    enum Fix: Hashable { case allowCalendar, privacySettings, openClaude, claudeTab, dismissError }
    var id: String
    var icon: String
    var title: String
    var detail: String
    var action: String
    var fix: Fix
}

/// The question and the two answers of an approval, by what is asked.
struct ApprovalWording {
    var question: String
    var yes: String
    var no: String

    init(_ request: ApprovalRequest) {
        let deleting = request.tool == "delete_event" || request.kind == .delete
        let many = request.items.count > 1
        switch request.kind {
        case .delete:
            self.init(question: many ? "DELETE THESE EVENTS?" : "DELETE THIS EVENT?", yes: "Delete", no: "Don't")
        case .notify:
            self.init(
                question: deleting ? "DELETE A SHARED EVENT?" : "CHANGE A SHARED EVENT?",
                yes: deleting ? "Delete" : "Change", no: "Don't")
        case .bulk:
            self.init(question: "CHANGE THESE EVENTS?", yes: "Go Ahead", no: "Don't")
        }
    }

    private init(question: String, yes: String, no: String) {
        self.question = question
        self.yes = yes
        self.no = no
    }
}

extension AgentModel {
    static let claudeAppBundleID = "com.anthropic.claudefordesktop"

    // MARK: Header

    var headline: String {
        if !pending.isEmpty {
            return pending.count == 1 ? "1 request waiting for your OK" : "\(pending.count) requests waiting for your OK"
        }
        if !attention.isEmpty {
            return attention.count == 1 ? "1 thing needs attention" : "\(attention.count) things need attention"
        }
        var parts = ["Ready"]
        if let next = nextEvent { parts.append("next \(next.title) \(relative(next.start))") }
        else if let last = activity.first { parts.append("last call \(last.date.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }

    var headlineColor: Color { !pending.isEmpty || !attention.isEmpty ? .orange : .green }

    var timed: [Event] { today.filter { !$0.isAllDay } }
    var allDay: [Event] { today.filter(\.isAllDay) }

    var currentEvents: [Event] {
        let now = clock()
        return timed.filter { $0.start <= now && $0.end > now }
    }

    var nextEvent: Event? {
        let now = clock()
        return timed.first { $0.start > now }
    }

    /// "in 25 min", "at 14:00".
    func relative(_ date: Date) -> String {
        let minutes = Int(date.timeIntervalSince(clock()) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return "at " + date.formatted(.dateTime.hour().minute())
    }

    /// Free time left today within working hours.
    var freeLeftToday: TimeInterval {
        let now = clock()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        return FreeTime.slots(events: today, from: now, to: end, duration: 15 * 60, hours: settings.workHours).reduce(0) { $0 + $1.duration }
    }

    var conflictsToday: Int { Conflicts.find(today).count }

    func color(of event: Event) -> Color {
        Color(hex: calendars.first { $0.id == event.calendarID }?.color ?? "#8E8E93")
    }

    /// The panel's footer on the Calendar tab.
    var footerLine: String {
        guard access.canRead else { return "No calendar access yet" }
        let visible = calendars.count - settings.hiddenCalendars.filter { id in calendars.contains { $0.id == id } }.count
        return "\(visible) calendar\(visible == 1 ? "" : "s") · \(Set(calendars.map(\.account)).count) accounts"
    }

    var updaterLine: String {
        switch updater.state {
        case .checking: " · checking…"
        case .upToDate: " · up to date"
        case .available(let release): " · \(release.version.description) available"
        case .installing(_, let progress): " · installing (\(Int(progress.fraction * 100))%)"
        case .failed(let message): " · \(message)"
        case .idle: ""
        }
    }

    /// A dot on the Claude tab: a client to connect or restart, or skills not added yet.
    var claudeNeedsAction: Bool {
        let code = clientStatus[.claudeCode] ?? .notInstalled
        let app = clientStatus[.claudeDesktop] ?? .notInstalled
        let codeTodo = code == .notInstalled || { if case .otherCommand = code { true } else { false } }()
        let appTodo = app == .notInstalled || { if case .otherCommand = app { true } else { false } }() || claudeAppNeedsRestart
        return codeTodo || appTodo || (code == .installed && installedSkillCount == 0)
    }

    // MARK: Needs attention

    var attention: [AttentionItem] {
        var items: [AttentionItem] = []
        if let lastError {
            items.append(AttentionItem(
                id: "error", icon: "exclamationmark.triangle", title: "Something didn't work", detail: lastError, action: "Dismiss",
                fix: .dismissError))
        }
        switch access {
        case .granted: break
        case .notDetermined:
            items.append(AttentionItem(
                id: "access", icon: "calendar.badge.plus", title: "Allow Calendar access",
                detail: "Claude reads and plans your calendars through this app. macOS asks once.", action: "Allow…", fix: .allowCalendar))
        case .writeOnly, .denied, .restricted, .unavailable:
            items.append(AttentionItem(
                id: "access", icon: "calendar.badge.exclamationmark", title: "Calendar access is off",
                detail: "Turn on Full Access for Apple Calendar MCP in Privacy & Security › Calendars.", action: "Open Settings…",
                fix: .privacySettings))
        }
        if let bridgeError {
            items.append(AttentionItem(
                id: "bridge", icon: "bolt.horizontal.circle", title: "Servers can't reach this app", detail: bridgeError, action: "Dismiss",
                fix: .dismissError))
        }
        if isSetUpTwiceInClaudeApp {
            items.append(AttentionItem(
                id: "claude-twice", icon: "square.on.square", title: "Apple Calendar is set up twice in Claude",
                detail: "Remove the Apple Calendar extension in Claude › Settings › Extensions; this app's entry stays and updates with it.",
                action: "Open Claude", fix: .openClaude))
        }
        for (client, version) in ActivityEntry.clientsOnOlderServer(in: activity) {
            items.append(AttentionItem(
                id: "older-server-\(client)", icon: "clock.arrow.circlepath", title: "\(client) uses an older server",
                detail: "It ran \(version ?? "an older version"), not \(CalendarMCPVersion.current). Restart it, and check which server it starts.",
                action: "Show setup", fix: .claudeTab))
        }
        return items
    }

    func perform(_ item: AttentionItem) {
        switch item.fix {
        case .allowCalendar: Task { await requestCalendarAccess() }
        case .privacySettings: openCalendarPrivacySettings()
        case .claudeTab: panelTab = .claude
        case .dismissError:
            if item.id == "bridge" { bridgeError = nil } else { lastError = nil }
        case .openClaude:
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeAppBundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    // MARK: Claude

    var installedSkillCount: Int {
        skillStates.values.filter { $0 == .installed || $0 == .updateAvailable }.count
    }

    var claudeCodeDetail: String {
        switch clientStatus[.claudeCode] ?? .notInstalled {
        case .installed:
            let skills = installedSkillCount
            return skills == 0 ? "Server connected · no skills yet" : "Server connected · \(skills) skill\(skills == 1 ? "" : "s")"
        case .otherCommand: return "Uses another calendar server; connect to switch"
        case .notInstalled: return "Adds the server and the skills"
        case .clientMissing: return "Claude Code isn't installed"
        }
    }

    var claudeAppDetail: String {
        switch clientStatus[.claudeDesktop] ?? .notInstalled {
        case .installed:
            return claudeAppNeedsRestart ? "Added. Restart Claude to load it." : "Server connected · skills: switch below to Claude app"
        case .otherCommand: return "Uses another calendar server; connect to switch"
        case .notInstalled: return "Adds the server; Claude needs a restart"
        case .clientMissing: return "The Claude app isn't installed"
        }
    }

    /// The config changed after the running Claude app read it: it only loads servers at launch.
    func computeClaudeAppNeedsRestart() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeAppBundleID).first,
              let launched = app.launchDate,
              let modified = (try? FileManager.default.attributesOfItem(atPath: clientInstaller.desktopConfigPath))?[.modificationDate] as? Date
        else { return false }
        return modified > launched
    }

    /// Server and every skill in one click.
    func connectClaudeCode() {
        install(in: .claudeCode)
        if clientStatus[.claudeCode] == .installed { installAllSkills() }
    }

    func installAllSkills() {
        selectedSkills = Set(SkillCatalog.all.map(\.name))
        installSelectedSkills()
        clientMessage = skillsMessage
    }

    /// Quits the Claude app and opens it again once it has exited, so it loads the new server.
    func restartClaudeApp() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeAppBundleID).first else { return }
        let pid = app.processIdentifier
        let url = app.bundleURL ?? URL(filePath: "/Applications/Claude.app")
        app.terminate()
        clientMessage = "Restarting Claude…"
        Task { @MainActor [weak self] in
            for _ in 0..<100 where NSRunningApplication(processIdentifier: pid) != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            self?.clientMessage = "Claude restarted with Apple Calendar. Its skills are added from the Claude app list below."
            self?.refreshClients()
        }
    }

    /// Zips the selected skills into ~/Downloads/Apple Calendar MCP Skills and shows them in Finder.
    func exportSkillsForClaudeApp() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Apple Calendar MCP Skills")
        do {
            let zips = try SkillInstaller.exportZips(SkillCatalog.all.filter { selectedSkills.contains($0.name) }, to: folder)
            NSWorkspace.shared.activateFileViewerSelecting(zips)
            skillsMessage = "Saved \(zips.count) skill\(zips.count == 1 ? "" : "s") to Downloads › Apple Calendar MCP Skills. In Claude, open Settings › Capabilities › Skills and upload each .zip."
        } catch {
            skillsMessage = "Could not export: \(error.localizedDescription)"
        }
    }
}

extension Color {
    /// `#RRGGBB`.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x8E8E93
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
