import CalendarMCPKit
import CalendarStore
import SwiftUI

// One surface, sections and rows (no stacked cards), the same look as Apple Mail MCP: Liquid Glass on the buttons over
// the system's glass menu window, quiet fills elsewhere. The approval is the only emphasized block.

// MARK: Building blocks

struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer()
            trailing.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        trailing = EmptyView()
    }
}

/// A list row: icon, title, detail, trailing control.
struct Row<Trailing: View>: View {
    let systemImage: String
    var iconColor: Color = .secondary
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 15)).foregroundStyle(iconColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

struct SectionDivider: View {
    var body: some View { Divider().padding(.horizontal, 16).padding(.top, 6) }
}

struct Checkmark: View {
    var body: some View {
        Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(.green).accessibilityLabel("Done")
    }
}

/// "Now" or "in 25 min" at the end of an event row.
struct Chip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.caption.weight(tint == nil ? .regular : .semibold).monospacedDigit())
            .foregroundStyle(tint ?? .secondary)
    }
}

// MARK: Menu bar panel: one place, three tabs

enum PanelTab: String, CaseIterable, Identifiable {
    case calendar = "Calendar"
    case claude = "Claude"
    case settings = "Settings"

    var id: String { rawValue }
}

struct MenuContent: View {
    @Bindable var model: AgentModel
    /// Fixes the tab (preview windows, snapshots); nil follows the model.
    var fixedTab: PanelTab?

    var tab: PanelTab { fixedTab ?? model.panelTab }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TabBar(model: model, selected: tab) { model.panelTab = $0 }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .calendar: CalendarTab(model: model)
                    case .claude: ClaudeTab(model: model)
                    case .settings: SettingsTab(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            }
            .frame(height: 470)
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Apple Calendar MCP").font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(model.headlineColor).frame(width: 7, height: 7)
                    Text(model.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            switch tab {
            case .claude:
                SkillActions(model: model)
            case .settings:
                SettingsLink { Text("More settings…") }.buttonStyle(.link)
                Spacer()
                Button("Check for Updates") { Task { await model.updater.check() } }
                    .disabled(!model.updater.isEnabled)
            case .calendar:
                Text(model.footerLine).font(.caption).foregroundStyle(.tertiary)
                Spacer()
            }
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit Apple Calendar MCP")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Segmented tab bar with a count badge on Calendar and a dot on Claude when something needs doing (as in Apple Mail MCP).
struct TabBar: View {
    @Bindable var model: AgentModel
    let selected: PanelTab
    let select: (PanelTab) -> Void
    /// One selection pill that slides from tab to tab, like a segmented control.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                Button { select(tab) } label: {
                    HStack(spacing: 5) {
                        Text(tab.rawValue)
                        if tab == .calendar, !model.pending.isEmpty {
                            Text("\(model.pending.count)")
                                .contentTransition(.numericText(value: Double(model.pending.count)))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(Color.orange))
                        }
                        if tab == .claude, model.claudeNeedsAction {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                        }
                    }
                    .font(.callout.weight(selected == tab ? .semibold : .regular))
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .contentShape(Rectangle())
                    .background {
                        if selected == tab {
                            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.14))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .focusEffectDisabled()
                .accessibilityAddTraits(selected == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
        .animatesChanges(of: selected)
        .animatesChanges(of: model.pending.count)
    }
}

// MARK: Calendar tab

struct CalendarTab: View {
    @Bindable var model: AgentModel

    /// The approval queue appears and leaves at once, so a Delete button never lingers on screen.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { update }
            .animatesChanges(of: [model.updater.availableRelease?.version.description, model.updater.installing != nil,
                                model.updater.installedElsewhere?.description] as [AnyHashable])
        if !model.pending.isEmpty {
            ApprovalQueue(model: model).padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 4).neverAnimated()
        }
        VStack(alignment: .leading, spacing: 0) { status }
            .animatesChanges(of: [model.attention.map(\.id), model.today.map(\.id), model.activity.first?.id] as [AnyHashable])
    }

    @ViewBuilder private var update: some View {
        if let (release, progress) = model.updater.installing {
            Row(systemImage: "arrow.down.circle.fill", iconColor: .accentColor, title: "Updating to version \(release.version.description)", detail: progress.step) {
                ProgressView(value: progress.fraction).frame(width: 110).accessibilityLabel("Update progress")
            }
        } else if let version = model.updater.installedElsewhere {
            Row(
                systemImage: "arrow.clockwise.circle.fill", iconColor: .accentColor,
                title: "Version \(version.description) is installed",
                detail: "Another account on this Mac updated Apple Calendar MCP. Relaunch to use it.")
            {
                Button("Relaunch") { model.updater.relaunchIntoInstalledVersion() }.glassButton(prominent: true).controlSize(.small)
            }
        } else if let release = model.updater.availableRelease {
            Row(
                systemImage: "arrow.down.circle.fill", iconColor: .accentColor, title: "Version \(release.version.description) is available",
                detail: model.updater.installBlocker
                    ?? (model.updater.needsAdministrator
                        ? "Asks for an administrator's password, then relaunches."
                        : "Installs and relaunches in a few seconds."))
            {
                if model.updater.installBlocker == nil {
                    Button("Update") { Task { await model.updater.install(release) } }.glassButton(prominent: true).controlSize(.small)
                } else {
                    Link("Download", destination: release.pageURL).controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if !model.attention.isEmpty {
            SectionHeader("Needs attention")
            ForEach(model.attention) { item in
                Row(systemImage: item.icon, iconColor: .orange, title: item.title, detail: item.detail) {
                    Button(item.action) { model.perform(item) }.glassButton(prominent: item.fix == .allowCalendar).controlSize(.small)
                }
            }
        }
        if model.access.canRead {
            TodaySection(model: model)
        }
        SectionHeader("Activity")
        if model.activity.isEmpty {
            Text("No requests yet. Ask Claude about your calendar.").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
        } else {
            ForEach(model.activity.prefix(12)) { entry in ActivityRow(entry: entry).padding(.horizontal, 16) }
        }
    }
}

/// Today in order: all-day events on one line, then the timed ones, with what is on now and what is next.
struct TodaySection: View {
    @Bindable var model: AgentModel

    var body: some View {
        let free = model.freeLeftToday
        SectionHeader("Today · " + model.clock().formatted(.dateTime.weekday(.wide).day().month(.abbreviated))) {
            Text(free >= 60 ? "\(Self.duration(free)) free" : "no free time left")
        }
        if !model.allDay.isEmpty {
            HStack(spacing: 6) {
                ForEach(model.allDay) { event in
                    HStack(spacing: 4) {
                        Circle().fill(model.color(of: event)).frame(width: 6, height: 6)
                        Text(event.title).lineLimit(1)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(model.color(of: event).opacity(0.14)))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        if model.timed.isEmpty {
            Text("Nothing scheduled.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
        }
        let conflicting = Set(Conflicts.find(model.today).flatMap { [$0.0.id, $0.1.id] })
        ForEach(model.timed.prefix(8)) { event in
            EventRow(model: model, event: event, conflict: conflicting.contains(event.id))
        }
        if model.timed.count > 8 {
            Text("\(model.timed.count - 8) more today").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 2)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)"
    }
}

struct EventRow: View {
    @Bindable var model: AgentModel
    let event: Event
    let conflict: Bool

    var body: some View {
        let now = model.clock()
        let isNow = event.start <= now && event.end > now
        let isPast = event.end <= now
        let isNext = model.nextEvent?.id == event.id
        // The Join button sits beside the row's own button, not inside it: a button in a button's label is unreliable.
        HStack(spacing: 8) {
            Button { model.open(event) } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(event.start, format: .dateTime.hour().minute()).font(.caption.monospacedDigit())
                        Text(event.end, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .frame(width: 44, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 1.5).fill(model.color(of: event)).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).font(.callout).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if conflict { Image(systemName: "exclamationmark.2").font(.caption).foregroundStyle(.orange).help("Overlaps another event") }
                    if isNow {
                        Chip(text: "Now", tint: .green)
                    } else if isNext {
                        Chip(text: model.relative(event.start))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help("Show in Calendar")
            if let call = joinable(now: now) {
                Button("Join") { NSWorkspace.shared.open(call) }
                    .glassButton(prominent: isNow).controlSize(.small)
                    .help("Join the video call (\(call.host() ?? "link"))")
                    .accessibilityLabel("Join \(event.title)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .opacity(isPast ? 0.5 : 1)
    }

    /// The call link of an event that is on, or starts within 10 minutes.
    private func joinable(now: Date) -> URL? {
        guard event.end > now, event.start.timeIntervalSince(now) <= 600, let link = VideoLink.find(in: event) else { return nil }
        return URL(string: link)
    }

    private var subtitle: String {
        var parts: [String] = []
        if VideoLink.find(in: event) != nil { parts.append("Video call") } else if let location = event.location { parts.append(location) }
        let others = event.otherPeople
        if !others.isEmpty {
            let names = others.prefix(2).map { $0.name?.components(separatedBy: " ").first ?? $0.email ?? "?" }
            parts.append("with " + names.joined(separator: ", ") + (others.count > 2 ? " +\(others.count - 2)" : ""))
        }
        if event.myStatus == .pending { parts.append("not answered") }
        if parts.isEmpty { parts.append(event.calendarTitle) }
        return parts.joined(separator: " · ")
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry

    /// A shape as well as a colour, so the state reads without telling green from orange.
    private var status: (symbol: String, color: Color, label: String) {
        if entry.running == true { return ("circle.dotted", .secondary, "Running") }
        if !entry.ok { return ("xmark.circle.fill", .red, "Failed") }
        return entry.isWrite ? ("diamond.fill", .orange, "Changed the calendar") : ("circle.fill", .green, "Read the calendar")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(status.color)
                .frame(width: 10).accessibilityLabel(status.label)
            Text(entry.tool.replacingOccurrences(of: "_", with: " ")).font(.caption).lineLimit(1)
                .frame(width: 132, alignment: .leading)
            Text(entry.summary).font(.caption).foregroundStyle(entry.ok ? .secondary : .primary).lineLimit(entry.ok ? 1 : 2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let link = entry.link, let url = URL(string: link) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app").font(.caption) }
                    .buttonStyle(.borderless).help("Show in Calendar").accessibilityLabel("Show in Calendar")
            }
            Text(entry.date, format: Calendar.current.isDateInToday(entry.date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .frame(minHeight: 22)
        .help("\(entry.summary)\n\(entry.client ?? "unknown client") · \(entry.milliseconds) ms\(entry.ok ? "" : " · failed")")
    }
}

// MARK: Approval

/// Several waiting requests: one shown in full with a pager, the others as one-line rows.
struct ApprovalQueue: View {
    @Bindable var model: AgentModel

    var focused: ApprovalRequest? { model.pending.first { $0.id == model.focusedApproval } ?? model.pending.first }

    var body: some View {
        if let focused {
            let index = model.pending.firstIndex { $0.id == focused.id } ?? 0
            VStack(alignment: .leading, spacing: 6) {
                ApprovalBlock(request: focused, position: model.pending.count > 1 ? (index, model.pending.count) : nil) { step in
                    let next = (index + step + model.pending.count) % model.pending.count
                    model.focusedApproval = model.pending[next].id
                } decide: { approve in
                    model.decide(focused, approve: approve)
                }
                let others = model.pending.filter { $0.id != focused.id }
                ForEach(others.prefix(Self.visibleOthers)) { other in
                    Button { model.focusedApproval = other.id } label: {
                        HStack(spacing: 8) {
                            Image(systemName: other.kind == .delete ? "trash" : "person.2").foregroundStyle(.orange).frame(width: 16)
                            Text(other.title).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(ApprovalWording(other).yes.lowercased()).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                if others.count > Self.visibleOthers {
                    Text("\(others.count - Self.visibleOthers) more waiting · the arrows above go through all of them")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
                }
            }
        }
    }

    static let visibleOthers = 5
}

struct ApprovalBlock: View {
    let request: ApprovalRequest
    @Environment(\.colorSchemeContrast) private var contrast
    var position: (Int, Int)?
    var page: (Int) -> Void = { _ in }
    let decide: (Bool) -> Void
    @State private var showAll = false

    init(request: ApprovalRequest, position: (Int, Int)? = nil, page: @escaping (Int) -> Void = { _ in }, decide: @escaping (Bool) -> Void) {
        self.request = request
        self.position = position
        self.page = page
        self.decide = decide
    }

    var body: some View {
        let wording = ApprovalWording(request)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(wording.question).font(.caption2.weight(.bold)).tracking(0.5).foregroundStyle(.orange)
                if let (index, count) = position {
                    HStack(spacing: 2) {
                        Button { page(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous request")
                        Text("\(index + 1) of \(count)").font(.caption2.monospacedDigit())
                        Button { page(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next request")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(request.client ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .help(request.tool.replacingOccurrences(of: "_", with: " "))
            }
            Text(request.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            if let detail = request.detail {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                    Text(detail)
                }
                .font(.callout)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array((showAll ? request.items : Array(request.items.prefix(5))).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if request.items.count > 5 {
                    Button(showAll ? "Show fewer" : "and \(request.items.count - 5) more") { showAll.toggle() }
                        .buttonStyle(.link).font(.caption).focusable(false)
                }
            }
            if !request.attendees.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Their calendar server may tell \(request.attendees.count == 1 ? "this person" : "these \(request.attendees.count) people"):")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(request.attendees.prefix(6).map { $0.components(separatedBy: " <").first ?? $0 }.joined(separator: ", ")
                         + (request.attendees.count > 6 ? " and \(request.attendees.count - 6) more" : ""))
                        .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if request.kind == .delete {
                    Text(request.subject == .reminder ? "undo_change can bring it back." : "Calendar has no Trash; undo_change can bring it back.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(wording.no, role: .cancel) { decide(false) }.glassButton()
                Button(wording.yes) { decide(true) }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(contrast == .increased ? 0.18 : 0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(contrast == .increased ? 0.9 : 0.35),
                                                                 lineWidth: contrast == .increased ? 1.5 : 1))
        .onChange(of: request.id) { showAll = false }
    }
}

struct ApprovalWindow: View {
    @Bindable var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.pending.isEmpty {
                Text("Nothing is waiting for approval.").foregroundStyle(.secondary)
            } else {
                ApprovalQueue(model: model)
            }
            Text("Nothing is deleted, and no event others are invited to is changed, without your OK. Requests cancel after \(Int(model.settings.approvalTimeout)) seconds.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .padding(.top, 4)
        .frame(width: 460)
    }
}

// MARK: Claude tab

struct ClaudeTab: View {
    @Bindable var model: AgentModel

    var body: some View {
        SectionHeader("Connections")
        ClaudeRows(model: model)
        if let message = model.clientMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 4)
        }
        SectionDivider()
        SectionHeader("Skills") {
            Picker("Skills for", selection: $model.skillTarget) {
                Text("Claude Code").tag(SkillTarget.claudeCode)
                Text("Claude app").tag(SkillTarget.claudeApp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        Text(model.skillTarget.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.bottom, 4)
        ForEach(SkillCatalog.all) { skill in SkillRow(model: model, skill: skill) }
        if let message = model.skillsMessage {
            Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }
}

struct SkillActions: View {
    @Bindable var model: AgentModel

    var body: some View {
        Text("\(model.selectedSkills.count) selected · \(model.installedSkillCount) in Claude Code").font(.caption).foregroundStyle(.secondary)
        Spacer()
        if model.skillTarget == .claudeCode {
            if model.selectedSkills.contains(where: { [.installed, .updateAvailable].contains(model.skillStates[$0]) }) {
                Button("Remove") { model.uninstallSelectedSkills() }
            }
            Button("Add \(model.selectedSkills.count)") { model.installSelectedSkills() }
                .glassButton(prominent: true).disabled(model.selectedSkills.isEmpty)
        } else {
            Button("Export \(model.selectedSkills.count)…") { model.exportSkillsForClaudeApp() }
                .glassButton(prominent: true).disabled(model.selectedSkills.isEmpty)
        }
    }
}

struct ClaudeRows: View {
    @Bindable var model: AgentModel

    var body: some View {
        let code = model.clientStatus[.claudeCode] ?? .notInstalled
        Row(systemImage: "terminal", title: "Claude Code", detail: model.claudeCodeDetail) {
            switch code {
            case .installed:
                if model.installedSkillCount == 0 {
                    Button("Add skills") { model.installAllSkills() }.glassButton().controlSize(.small)
                } else {
                    Checkmark().contextMenu { Button("Remove from Claude Code") { model.uninstall(from: .claudeCode) } }
                }
            case .clientMissing:
                Text("Not installed").font(.caption).foregroundStyle(.tertiary)
            case .notInstalled, .otherCommand:
                Button("Connect") { model.connectClaudeCode() }.glassButton(prominent: true).controlSize(.small)
            }
        }
        let app = model.clientStatus[.claudeDesktop] ?? .notInstalled
        Row(systemImage: "macwindow", title: "Claude app", detail: model.claudeAppDetail) {
            switch app {
            case .installed:
                if model.claudeAppNeedsRestart {
                    Button("Restart Claude") { model.restartClaudeApp() }.glassButton(prominent: true).controlSize(.small)
                } else {
                    Checkmark().contextMenu { Button("Remove from the Claude app") { model.uninstall(from: .claudeDesktop) } }
                }
            case .clientMissing:
                Text("Not installed").font(.caption).foregroundStyle(.tertiary)
            case .notInstalled, .otherCommand:
                Button("Connect") { model.install(in: .claudeDesktop) }.glassButton(prominent: true).controlSize(.small)
            }
        }
    }
}

struct SkillRow: View {
    @Bindable var model: AgentModel
    let skill: CalendarSkill

    var state: SkillInstaller.State { model.skillStates[skill.name] ?? .notInstalled }

    var badge: (String, Color) {
        switch state {
        case .installed: ("Installed", .green)
        case .updateAvailable: ("Update", .orange)
        case .foreign: ("Name taken", .secondary)
        case .notInstalled: ("Not added", .secondary)
        }
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.selectedSkills.contains(skill.name) },
            set: { selected in
                if selected { model.selectedSkills.insert(skill.name) } else { model.selectedSkills.remove(skill.name) }
            }))
        {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    SlashCommand(name: skill.name)
                    Text(skill.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(badge.0).font(.caption).foregroundStyle(badge.1)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(state == .foreign)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

/// `/calendar-daily-brief`: how to run a skill in Claude Code. Click copies it.
struct SlashCommand: View {
    let name: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("/\(name)", forType: .string)
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { copied = false }
            }
        } label: {
            Text(copied ? "Copied /\(name)" : "/\(name)")
                .font(.callout.monospaced())
                .foregroundStyle(copied ? Color.green : Color.orange)
                .contentTransition(.opacity)
        }
        .buttonStyle(.borderless)
        .animatesChanges(of: copied)
        .help("Type /\(name) in Claude Code to run this skill. Click to copy.")
    }
}

// MARK: Settings tab

struct SettingsTab: View {
    @Bindable var model: AgentModel

    var body: some View {
        SectionHeader("Changes")
        SettingRow("Allow Claude to change the calendar") { Toggle("", isOn: $model.settings.allowCalendarChanges).labelsHidden() }
        SettingRow("When Claude deletes events") {
            PolicyPicker(selection: $model.settings.deletePolicy, allow: "Delete right away", never: "Never delete")
        }
        SettingRow("Events other people are invited to") {
            PolicyPicker(selection: $model.settings.sharedEventPolicy, allow: "Change right away", never: "Never change")
        }
        Text("Their calendar server may tell them when an event changes or goes.").font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16)
        SettingRow("Events per change, at most") {
            Stepper("\(model.settings.maxBatchSize)", value: $model.settings.maxBatchSize, in: 1...500).fixedSize()
        }
        SectionDivider()
        SectionHeader("Working hours") { Text("for free time") }
        HStack(spacing: 10) {
            TimeField(text: $model.settings.workdayStart)
            Text("to").foregroundStyle(.secondary)
            TimeField(text: $model.settings.workdayEnd)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        WeekdayPicker(selection: $model.settings.workdays).padding(.horizontal, 16).padding(.bottom, 4)
        SectionDivider()
        SectionHeader("What Claude can do with each calendar") { Text("\(model.settings.visible(model.calendars).count) of \(model.calendars.count) seen") }
        if model.calendars.isEmpty {
            Text("Allow Calendar access to choose.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 4)
        }
        ForEach(model.calendars) { calendar in
            CalendarAccessRow(model: model, calendar: calendar)
        }
        SectionDivider()
        SectionHeader("Reminders") {
            if model.reminderAccess.canRead { Text("\(model.settings.visible(model.reminderLists).count) of \(model.reminderLists.count) seen") }
        }
        switch model.reminderAccess {
        case .granted:
            ForEach(model.reminderLists) { list in CalendarAccessRow(model: model, calendar: list) }
        case .notDetermined:
            Row(systemImage: "checklist", title: "Let Claude use Reminders", detail: "List, add and complete reminders. macOS asks once.") {
                Button("Allow…") { Task { await model.requestAccess(to: .reminder) } }.glassButton().controlSize(.small)
            }
        case .writeOnly, .denied, .restricted, .unavailable:
            Row(systemImage: "checklist", title: "Reminders access is off", detail: "Turn on Full Access in Privacy & Security › Reminders.") {
                Button("Open Settings…") { model.openPrivacySettings("Privacy_Reminders") }.glassButton().controlSize(.small)
            }
        }
        SectionDivider()
        SectionHeader("App")
        SettingRow("Show the next event in the menu bar") { Toggle("", isOn: $model.settings.showNextEventInMenuBar).labelsHidden() }
        SettingRow("Check for updates every day") {
            Toggle("", isOn: $model.settings.checkForUpdates).labelsHidden().disabled(!model.updater.isEnabled)
        }
        SettingRow("Update installed skills with the app") { Toggle("", isOn: $model.settings.updateInstalledSkills).labelsHidden() }
        SettingRow("Open at login") {
            Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })).labelsHidden()
        }
        Text("Version \(model.updater.currentVersion?.description ?? CalendarMCPVersion.current)\(model.updaterLine)")
            .font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.top, 8)
            .onChange(of: model.settings) { model.save() }
    }
}

/// One calendar (or reminder list) and what Claude may do with it: change, only read, or not see.
struct CalendarAccessRow: View {
    @Bindable var model: AgentModel
    let calendar: CalendarInfo

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: calendar.color)).frame(width: 8, height: 8)
            Text(calendar.title).font(.callout).lineLimit(1)
            Text(calendar.account).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Picker("", selection: Binding(
                get: { model.settings.access(calendar.id) == .read && !calendar.writable ? .change : model.settings.access(calendar.id) },
                set: { model.settings.setAccess(calendar.id, $0) }))
            {
                Text(calendar.writable ? "Read and change" : "Read (read-only)").tag(Settings.CalendarAccess.change)
                if calendar.writable { Text("Read only").tag(Settings.CalendarAccess.read) }
                Text("Hidden").tag(Settings.CalendarAccess.hidden)
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Claude's access to \(calendar.title)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 26)
    }
}

struct PolicyPicker: View {
    @Binding var selection: Policy
    let allow: String
    let never: String

    var body: some View {
        Picker("", selection: $selection) {
            Text("Ask me first").tag(Policy.confirm)
            Text(allow).tag(Policy.allow)
            Text(never).tag(Policy.never)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// `HH:MM` as a time picker.
struct TimeField: View {
    @Binding var text: String

    var body: some View {
        DatePicker("", selection: Binding(
            get: {
                let minutes = WorkHours.minutes(text) ?? 9 * 60
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                text = WorkHours.text((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.field)
            .fixedSize()
    }
}

/// Working days as a row of toggles, Monday first, in the tab bar's segmented style.
struct WeekdayPicker: View {
    @Binding var selection: [Int]

    var body: some View {
        HStack(spacing: 2) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.removeAll { $0 == day } } else { selection = (selection + [day]).sorted() }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .font(.caption.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .frame(width: 30, height: 22)
                        .contentShape(Rectangle())
                        .background { if on { RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.14)) } }
                }
                .buttonStyle(PressableButtonStyle())
                .focusEffectDisabled()
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
        .fixedSize()
        .animatesChanges(of: selection)
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            control.toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 34)
    }
}

// MARK: Settings window

struct SettingsView: View {
    @Bindable var model: AgentModel

    var body: some View {
        Form {
            Section("Approvals") {
                Stepper("Wait up to \(Int(model.settings.approvalTimeout)) s for my answer", value: $model.settings.approvalTimeout, in: 30...600, step: 30)
            }
            Section("Files") {
                TextField("Import and export only in (folders, comma-separated)", text: Binding(
                    get: { model.settings.fileDirectories.joined(separator: ", ") },
                    set: { model.settings.fileDirectories = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
            }
            Section("Claude") {
                ClaudeRows(model: model)
                LabeledContent("Server") { Text(model.serverPath).font(.caption.monospaced()).textSelection(.enabled) }
                HStack {
                    Button("Copy Claude Code command") { model.copy(model.claudeCodeCommand) }
                    Button("Copy Claude app config") { model.copy(model.desktopConfig) }
                }
            }
            Section("Calendar access") {
                LabeledContent("Status") { Text(EventKitBackend.explain(model.access)) }
                LabeledContent("Reminders") { Text(EventKitBackend.explainReminders(model.reminderAccess)) }
                Button("Open Privacy & Security › Calendars…") { model.openCalendarPrivacySettings() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 460)
        .onChange(of: model.settings) { model.save() }
    }
}
