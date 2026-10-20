import SwiftUI
import AppKit

// All colors are semantic (primary/secondary/system green/accent), so the panel
// follows the macOS Light/Dark/Auto appearance and switches live.

struct PanelView: View {
    @EnvironmentObject private var model: VigilModel
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusHeader()

            ModePicker()

            if !model.hooksInstalled { ConnectCard() }

            ActivitySection()
            Divider()
            SettingsSection()

            if let message = model.errorMessage { ErrorBanner(message: message) }
            if let version = updater.pendingVersion { UpdateBanner(version: version) }

            Divider()
            Footer()
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            model.refreshStatus()
            model.tick()
        }
    }
}

// MARK: - Header

private struct StatusHeader: View {
    @EnvironmentObject private var model: VigilModel
    @State private var onScreen = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(model.isActive ? 0.18 : 0.10))
                if model.isActive && onScreen { PulseRing(color: tint) }
                Image(systemName: model.menuIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .background(WindowVisibility(isVisible: $onScreen))
    }

    private var tint: Color { model.isActive ? .green : .secondary }

    private var title: String {
        if model.mode == .timed, let end = model.timerEnd {
            return "Awake until \(end.formatted(date: .omitted, time: .shortened))"
        }
        switch (model.mode, model.isActive) {
        case (.off, _):      return "Sleep guard off"
        case (.alwaysOn, _): return "Always awake"
        case (_, true):      return "Keeping Mac awake"
        default:             return "Sleep allowed"
        }
    }

    @ViewBuilder private var subtitle: some View {
        if model.mode == .off {
            Text("Your Mac sleeps normally")
        } else if model.mode == .timed, let end = model.timerEnd {
            (Text(end, style: .timer) + Text(" left") + Text(agentsSuffix)).monospacedDigit()
        } else if model.isActive, let since = model.awakeSince {
            (Text("Awake for ") + Text(since, style: .timer) + Text(agentsSuffix)).monospacedDigit()
        } else {
            Text("Waiting for an agent to start")
        }
    }

    private var agentsSuffix: String {
        let n = model.activeCount
        return n == 0 ? "" : " · \(n) agent\(n == 1 ? "" : "s")"
    }
}

private struct PulseRing: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        Circle()
            .stroke(color.opacity(0.5), lineWidth: 2)
            .scaleEffect(animate ? 1.35 : 1)
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

/// Whether the panel's window is on screen. MenuBarExtra only hides the window on
/// close, so the view tree stays alive and a running animation would keep rendering
/// (~13% CPU) for as long as an agent works.
private struct WindowVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> NSView { Probe(isVisible: $isVisible) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private let isVisible: Binding<Bool>
        private var observer: NSObjectProtocol?

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main
                ) { [weak self] _ in self?.report() }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            // Deferred: this can run mid view-update, where writing state is not allowed.
            DispatchQueue.main.async { [isVisible] in
                if isVisible.wrappedValue != visible { isVisible.wrappedValue = visible }
            }
        }
    }
}

// MARK: - Mode picker

/// Auto | Always | Off | Timer ▾. SwiftUI's segmented Picker can't give a segment a menu,
/// so this is the AppKit control; clicking Timer drops down the lengths to stay awake for.
private struct ModePicker: NSViewRepresentable {
    @EnvironmentObject private var model: VigilModel

    private static let timerSegment = Mode.allCases.firstIndex(of: .timed)!

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Mode.allCases.map(\.title), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.segmentClicked(_:))
        )
        control.segmentDistribution = .fillEqually
        control.setMenu(context.coordinator.menu, forSegment: Self.timerSegment)
        control.setShowsMenuIndicator(true, forSegment: Self.timerSegment)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        let timing = model.mode == .timed
        control.setLabel(timing ? Coordinator.length(model.timerMinutes, .abbreviated) : Mode.timed.title,
                         forSegment: Self.timerSegment)
        control.selectedSegment = Mode.allCases.firstIndex(of: model.mode) ?? 0
        for item in context.coordinator.menu.items {
            item.state = timing && item.tag == model.timerMinutes ? .on : .off
        }
    }

    /// Full width, like the segmented Picker it replaces.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let fitting = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    @MainActor final class Coordinator: NSObject {
        let menu = NSMenu()
        private let model: VigilModel

        init(model: VigilModel) {
            self.model = model
            super.init()
            for minutes in VigilModel.timerOptions {
                let item = NSMenuItem(title: Self.length(minutes, .full), action: #selector(startTimer(_:)), keyEquivalent: "")
                item.target = self
                item.tag = minutes
                menu.addItem(item)
            }
        }

        /// "2h" for the segment, "2 hours" for the menu.
        static func length(_ minutes: Int, _ style: DateComponentsFormatter.UnitsStyle) -> String {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = style
            formatter.allowedUnits = [.hour, .minute]
            return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes)m"
        }

        @objc func segmentClicked(_ control: NSSegmentedControl) {
            let picked = Mode.allCases[control.selectedSegment]
            guard picked == .timed else { model.mode = picked; return }

            // Timer itself only opens the menu; picking a length starts it.
            let width = control.bounds.width / CGFloat(control.segmentCount)
            let below = NSPoint(x: width * CGFloat(control.selectedSegment), y: control.isFlipped ? control.bounds.maxY + 4 : -4)
            menu.popUp(positioning: nil, at: below, in: control)
            control.selectedSegment = Mode.allCases.firstIndex(of: model.mode) ?? 0
        }

        @objc private func startTimer(_ item: NSMenuItem) {
            model.startTimer(minutes: item.tag)
        }
    }
}

// MARK: - Connect card

private struct ConnectCard: View {
    @EnvironmentObject private var model: VigilModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect Claude Code").font(.callout.weight(.semibold))
            Text("Stay awake exactly while Claude works, not just while it's open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect") { model.installHooks() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }
}

// MARK: - Activity

private struct ActivitySection: View {
    @EnvironmentObject private var model: VigilModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Activity")
            if model.sessions.isEmpty && model.processes.isEmpty {
                Label(model.mode == .automatic ? "No agents working" : "Detection paused", systemImage: "moon.stars")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ForEach(model.sessions) { SessionRow(session: $0) }
                ForEach(model.processes, id: \.self) { ProcessRow(name: $0) }
            }
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: VigilModel
    let session: SessionRecord
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle")
                .foregroundStyle(.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if hovering {
                Button { model.release(session.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Release — let the Mac sleep")
            } else {
                Text(session.started, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
        .onHover { hovering = $0 }
    }
}

private struct ProcessRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                Text("Process running").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Circle().fill(Color.green).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @EnvironmentObject private var model: VigilModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Settings")
            SettingToggle(title: "Keep display on", isOn: $model.keepDisplayAwake)
            SettingToggle(title: "Watch other agents", isOn: $model.watchProcesses)
            if model.watchProcesses { PatternEditor() }
            SettingToggle(title: "Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
    }
}

private struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

private struct PatternEditor: View {
    @EnvironmentObject private var model: VigilModel
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(model.patterns, id: \.self) { p in
                Chip(text: p, running: model.processes.contains(p)) { model.removePattern(p) }
            }
            HStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                TextField("Add", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 70)
                    .onSubmit {
                        model.addPattern(draft)
                        draft = ""
                    }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2])))
        }
    }
}

private struct Chip: View {
    let text: String
    let running: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if running { Circle().fill(Color.green).frame(width: 6, height: 6) }
            Text(text).font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop watching \(text)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - Banners + footer

private struct UpdateBanner: View {
    @EnvironmentObject private var updater: Updater
    let version: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            Text("Vigil \(version) is available").font(.caption)
            Spacer(minLength: 0)
            Button("Update") { updater.checkForUpdates() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }
}

private struct ErrorBanner: View {
    @EnvironmentObject private var model: VigilModel
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

private struct Footer: View {
    @EnvironmentObject private var model: VigilModel
    @EnvironmentObject private var updater: Updater

    var body: some View {
        HStack(spacing: 10) {
            if model.hooksInstalled {
                Label("Claude Code connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Claude Code not connected", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(version)")
                .foregroundStyle(.tertiary)
            Menu {
                if model.hooksInstalled {
                    Button("Disconnect Claude Code") { model.removeHooks() }
                } else {
                    Button("Connect Claude Code") { model.installHooks() }
                }
                Button("Show Sessions Folder") { model.openSessionsFolder() }
                Divider()
                Button("Check for Updates…") { updater.checkForUpdates() }
                Toggle("Update Automatically", isOn: $updater.updatesAutomatically)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .font(.caption)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

private struct SectionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
}
