import AppKit
import CalendarFixtures
import CalendarMCPKit
import CalendarStore
import EventKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// State and background work of the menu bar agent: it holds the Calendars permission, serves it to the MCP servers
/// over the bridge, and asks the user when a server wants to delete or change shared events.
@MainActor
@Observable
final class AgentModel {
    var settings: Settings
    var access: AccessState = .notDetermined
    var calendars: [CalendarInfo] = []
    /// Today's events from the visible calendars, declined and cancelled ones left out.
    var today: [Event] = []
    var activity: [ActivityEntry] = []
    var pending: [ApprovalRequest] = []
    /// Which waiting request the panel shows in full when several wait.
    var focusedApproval: UUID?
    var lastError: String?
    /// Why servers cannot reach this app (unsigned build, socket error); nil when the bridge is up.
    var bridgeError: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var skillStates: [String: SkillInstaller.State] = [:]
    var selectedSkills = Set<String>()
    var skillsMessage: String?
    let skillInstaller = SkillInstaller()
    var clientStatus: [ClientInstaller.Client: ClientInstaller.Status] = [:]
    var clientMessage: String?
    let updater = Updater()
    var skillTarget: SkillTarget = .claudeCode
    var panelTab: PanelTab = .calendar
    private(set) var claudeAppNeedsRestart = false
    private(set) var isSetUpTwiceInClaudeApp = false

    /// `--demo`: the made-up week, no bridge, nothing saved (screenshots).
    let demo: Bool
    let backend: any CalendarBackend
    let log = ActivityLog()
    @ObservationIgnored private var host: BridgeHost?
    @ObservationIgnored private var waiting: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var activityStamp: ActivityLog.Stamp?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var calendarRefresh: Task<Void, Never>?
    @ObservationIgnored private var calendarGeneration = 0
    var openApprovalWindow: (() -> Void)?
    var closeApprovalWindow: (() -> Void)?

    /// The time the panel shows (the demo fixes it so screenshots always show a busy morning).
    let clock: () -> Date

    init(demo: Bool) {
        self.demo = demo
        if demo {
            let morning = Calendar.current.date(bySettingHour: 10, minute: 15, second: 0, of: Date())!
            backend = StandardFixture.backend(now: morning)
            clock = { morning }
            settings = Settings()
        } else {
            backend = EventKitBackend()
            clock = { Date() }
            settings = Settings.load()
        }
    }

    /// Path of the MCP server binary that ships in this app (its own bundle in Contents/Helpers).
    let serverPath: String = {
        let helper = Bundle.main.bundleURL.appending(path: ClientInstaller.helperExecutable).path
        if FileManager.default.isExecutableFile(atPath: helper) { return helper }
        let besideExecutable = (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/apple-calendar-mcp"
        return FileManager.default.isExecutableFile(atPath: besideExecutable) ? besideExecutable : "apple-calendar-mcp"
    }()

    var clientInstaller: ClientInstaller { ClientInstaller(serverPath: serverPath) }

    var claudeCodeCommand: String { "claude mcp add apple-calendar -- \"\(serverPath)\"" }

    var desktopConfig: String {
        """
        {
          "mcpServers": {
            "apple-calendar": { "command": "\(serverPath)" }
          }
        }
        """
    }

    func start() {
        guard tasks.isEmpty else { return }
        if demo {
            updater.checkSignature()
            refreshClients()
            loadDemoActivity()
        } else {
            // First, so a server that just opened the app finds the socket soon.
            startBridge()
            requestNotificationPermission()
            updater.automaticChecks = { [weak self] in self?.settings.checkForUpdates ?? true }
            updater.start()
            refreshClientsInBackground()
            refreshInstalledSkills()
            // Calendar changes (here, in Calendar, synced from elsewhere) refresh the day; a sync sends them in bursts.
            observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCalendar(after: 0.5) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCalendar() }
            })
        }
        refreshSkills()
        refreshCalendar()
        tasks.append(Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !self.demo { self.refreshActivity() }
                if tick % 15 == 0 {
                    // Changes and the day turning are observed; only the permission is polled.
                    if self.backend.access() != self.access { self.refreshCalendar() }
                    if !self.demo { self.refreshClientsInBackground() }
                    self.launchAtLogin = SMAppService.mainApp.status == .enabled
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        })
    }

    // MARK: Calendar access and the bridge

    func requestCalendarAccess() async {
        guard let eventKit = backend as? EventKitBackend else { return }
        if EventKitBackend.authorization() == .denied {
            openCalendarPrivacySettings()
            return
        }
        NSApp.activate()
        access = await eventKit.requestAccess()
        refreshCalendar()
    }

    private func startBridge() {
        do {
            let requirement = try PeerRequirement.matchingSelf()
            let host = BridgeHost(
                socket: SharedPaths.bridgeSocket, backend: backend, requirement: requirement,
                info: BridgeInfo(version: CalendarMCPVersion.build, pid: ProcessInfo.processInfo.processIdentifier)
            ) { [weak self] request, timeout in
                await self?.ask(request, timeout: timeout) ?? .timedOut
            }
            try host.start()
            self.host = host
            bridgeError = nil
        } catch {
            bridgeError = String(describing: error)
        }
    }

    func stopBridge() { host?.stop() }

    /// Reloads calendars and today's events off the main thread (a long query from a server holds EventKit), then
    /// shows them; `delay` coalesces bursts. The demo reads its memory week right away, for snapshots.
    func refreshCalendar(after delay: TimeInterval = 0) {
        if demo {
            apply(Self.calendarSnapshot(backend, settings, clock()))
            return
        }
        calendarGeneration += 1
        let generation = calendarGeneration
        let (backend, settings, now) = (backend, settings, clock())
        calendarRefresh?.cancel()
        calendarRefresh = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let snapshot = await Task.detached { Self.calendarSnapshot(backend, settings, now) }.value
            guard let self, generation == self.calendarGeneration else { return }
            self.apply(snapshot)
        }
    }

    private struct CalendarSnapshot: Sendable {
        var access: AccessState
        var calendars: [CalendarInfo]
        var today: [Event]
    }

    private nonisolated static func calendarSnapshot(_ backend: any CalendarBackend, _ settings: Settings, _ now: Date) -> CalendarSnapshot {
        let access = backend.access()
        guard access.canRead else { return CalendarSnapshot(access: access, calendars: [], today: []) }
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return CalendarSnapshot(
            access: access, calendars: (try? backend.calendars()) ?? [],
            today: settings.visible((try? backend.events(in: start, end)) ?? []).filter(\.isAttended))
    }

    private func apply(_ snapshot: CalendarSnapshot) {
        if snapshot.access != access { access = snapshot.access }
        if snapshot.calendars != calendars { calendars = snapshot.calendars }
        if snapshot.today != today { today = snapshot.today }
    }

    // MARK: Approvals

    /// Shows `request` and waits for the user's answer, at most `timeout` seconds.
    func ask(_ request: ApprovalRequest, timeout: TimeInterval) async -> ApprovalDecision {
        pending.append(request)
        notify(request)
        panelTab = .calendar
        openApprovalWindow?()
        let id = request.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finish(id, .timedOut)
        }
        return await withCheckedContinuation { continuation in waiting[id] = continuation }
    }

    func decide(_ request: ApprovalRequest, approve: Bool) {
        finish(request.id, approve ? .approved : .denied)
    }

    private func finish(_ id: UUID, _ decision: ApprovalDecision) {
        pending.removeAll { $0.id == id }
        if focusedApproval == id { focusedApproval = pending.first?.id }
        if pending.isEmpty { closeApprovalWindow?() }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        waiting.removeValue(forKey: id)?.resume(returning: decision)
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ request: ApprovalRequest) {
        guard !demo, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = ApprovalWording(request).question.capitalized
        content.subtitle = request.title
        content.body = request.client.map { "From \($0)" } ?? ""
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id.uuidString, content: content, trigger: nil))
    }

    // MARK: Activity

    func refreshActivity() {
        let stamp = log.stamp()
        guard stamp != activityStamp else { return }
        activityStamp = stamp
        let entries = log.recent(limit: 40)
        if entries != activity { activity = entries }
    }

    private func loadDemoActivity() {
        let now = clock()
        let calls: [(String, String, Bool, Int)] = [
            ("agenda", "4 events, 1 conflict", false, 2), ("find_free_time", "6 slots", false, 3),
            ("create_event", "created 1 event", true, 9), ("search_events", "12 matches", false, 14),
            ("calendar_statistics", "38 events, 14 h of meetings", false, 31), ("update_event", "updated 1 event", true, 47),
        ]
        activity = calls.map { tool, summary, write, minutes in
            ActivityEntry(
                date: now.addingTimeInterval(TimeInterval(-minutes * 60)), pid: 1, client: "Claude Code", tool: tool, ok: true,
                milliseconds: write ? 41 : 6, summary: summary, isWrite: write)
        }
    }

    /// `--approval N` in demo mode: N waiting requests about the demo week, nothing behind them.
    func loadDemoApprovals(_ count: Int) {
        let start = Calendar.current.startOfDay(for: clock())
        let week = (try? backend.events(in: start, start.addingTimeInterval(7 * 86_400))) ?? []
        var samples: [ApprovalRequest] = []
        if let sync = week.first(where: { $0.title == "Engineering sync" }) {
            let moved = sync.start.addingTimeInterval(45 * 60)
            samples.append(ApprovalRequest(
                tool: "update_event", client: "Claude Code", kind: .notify, title: sync.title, items: [sync.summaryLine],
                attendees: sync.attendees.filter { !$0.isCurrentUser }.map(\.formatted),
                detail: "Moves to " + moved.formatted(.dateTime.weekday(.abbreviated).hour().minute()) + "–"
                    + moved.addingTimeInterval(sync.duration).formatted(.dateTime.hour().minute())))
        }
        let personal = week.filter { ["Swimming lessons", "Dentist"].contains($0.title) }.prefix(2)
        if !personal.isEmpty {
            samples.append(ApprovalRequest(tool: "delete_event", client: "Claude", kind: .delete, title: "\(personal.count) events", items: personal.map(\.summaryLine)))
        }
        if let focus = week.first(where: { $0.title.hasPrefix("Focus") }) {
            samples.append(ApprovalRequest(tool: "delete_event", client: "Claude Code", kind: .delete, title: focus.title, items: [focus.summaryLine]))
        }
        pending = Array(samples.prefix(count))
    }

    // MARK: Claude clients

    /// Right away, after the user changed something (the caller reads the new status).
    func refreshClients() { apply(Self.clientSnapshot(clientInstaller)) }

    /// The periodic look: the Claude config files can be several megabytes, so they are read off the main thread.
    func refreshClientsInBackground() {
        let installer = clientInstaller
        Task { [weak self] in
            let snapshot = await Task.detached { Self.clientSnapshot(installer) }.value
            self?.apply(snapshot)
        }
    }

    private struct ClientSnapshot: Sendable {
        var status: [ClientInstaller.Client: ClientInstaller.Status]
        var claudeAppNeedsRestart: Bool
        var setUpTwice: Bool
    }

    private nonisolated static func clientSnapshot(_ installer: ClientInstaller) -> ClientSnapshot {
        let status = Dictionary(uniqueKeysWithValues: ClientInstaller.Client.allCases.map { ($0, installer.status($0)) })
        // The Claude app reads its config at launch: a newer entry needs a restart.
        let launched = NSRunningApplication.runningApplications(withBundleIdentifier: claudeAppBundleID).first?.launchDate
        let restart = launched.flatMap { launched in installer.desktopEntryChanged.map { $0 > launched } } ?? false
        return ClientSnapshot(
            status: status, claudeAppNeedsRestart: restart,
            setUpTwice: installer.isSetUpTwiceInClaudeDesktop(desktopStatus: status[.claudeDesktop] ?? .notInstalled))
    }

    private func apply(_ snapshot: ClientSnapshot) {
        if snapshot.status != clientStatus { clientStatus = snapshot.status }
        if snapshot.claudeAppNeedsRestart != claudeAppNeedsRestart { claudeAppNeedsRestart = snapshot.claudeAppNeedsRestart }
        if snapshot.setUpTwice != isSetUpTwiceInClaudeApp { isSetUpTwiceInClaudeApp = snapshot.setUpTwice }
    }

    func install(in client: ClientInstaller.Client) {
        do {
            clientMessage = try clientInstaller.install(client)
        } catch {
            clientMessage = "Could not add to \(client.displayName): \(error)"
        }
        refreshClients()
    }

    func uninstall(from client: ClientInstaller.Client) {
        do {
            try clientInstaller.uninstall(client)
            clientMessage = "Removed from \(client.displayName)."
        } catch {
            clientMessage = "Could not remove from \(client.displayName): \(error)"
        }
        refreshClients()
    }

    // MARK: Skills

    func refreshSkills() {
        skillStates = Dictionary(uniqueKeysWithValues: SkillCatalog.all.map { ($0.name, skillInstaller.state(of: $0)) })
        if selectedSkills.isEmpty {
            selectedSkills = Set(SkillCatalog.all.filter { [.notInstalled, .updateAvailable].contains(skillStates[$0.name]) }.map(\.name))
        }
    }

    /// Runs at launch, so an app update also updates the skills it installed earlier.
    func refreshInstalledSkills() {
        guard settings.updateInstalledSkills else { return }
        if let updated = try? skillInstaller.refreshInstalled(), !updated.isEmpty {
            skillsMessage = "Updated \(plural(updated.count, "Claude skill")) to this version."
        }
    }

    private var chosenSkills: [CalendarSkill] { SkillCatalog.all.filter { selectedSkills.contains($0.name) } }

    func installSelectedSkills() {
        do {
            let done = try skillInstaller.install(chosenSkills)
            skillsMessage = "Added \(plural(done.count, "skill")) to Claude Code (~/.claude/skills). New Claude Code sessions pick them up."
        } catch {
            skillsMessage = "Could not install: \(error.localizedDescription)"
        }
        selectedSkills = []
        refreshSkills()
    }

    func uninstallSelectedSkills() {
        do {
            let removed = try skillInstaller.uninstall(chosenSkills)
            skillsMessage = "Removed \(plural(removed.count, "skill"))."
        } catch {
            skillsMessage = "Could not remove: \(error.localizedDescription)"
        }
        selectedSkills = []
        refreshSkills()
    }

    // MARK: Settings

    func save() {
        guard !demo else { return }
        do {
            try settings.save()
            if lastError?.hasPrefix("Could not save settings") == true { lastError = nil }
        } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
        }
        refreshCalendar()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Open at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openCalendarPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    func open(_ event: Event) {
        Task { await NSWorkspace.shared.showInCalendar(event.calendarLinks) }
    }
}
