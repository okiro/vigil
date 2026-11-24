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
                if model.isWindingDown {
                    WindDownRing(level: model.windDownLevel, color: tint)
                } else if model.isActive && onScreen {
                    PulseRing(color: tint)
                }
                glyph.foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                title.font(.headline).monospacedDigit()
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isWindingDown {
                Button("Sleep now") { model.sleepNow() }
                    .controlSize(.small)
                    .help("Stop waiting and let the Mac sleep")
            }
        }
        .background(WindowVisibility(isVisible: $onScreen))
    }

    private var tint: Color { model.lidArmed ? .red : model.isActive ? .green : .secondary }

    @ViewBuilder private var glyph: some View {
        if model.isWindingDown, let cup = CupIcon.image(level: model.windDownLevel, pointSize: 18, weight: .semibold) {
            Image(nsImage: cup).renderingMode(.template)
        } else {
            Image(systemName: model.menuIcon).font(.system(size: 18, weight: .semibold))
        }
    }

    private var title: Text {
        if model.mode == .timed, let end = model.timerEnd {
            return Text("Awake until \(end.formatted(date: .omitted, time: .shortened))")
        }
        if let end = model.windDownEnd {
            return Text("Sleeping in ") + Text(end, style: .timer)
        }
        switch (model.mode, model.isActive) {
        case (.off, _):      return Text("Sleep guard off")
        case (.alwaysOn, _): return Text("Always awake")
        case (_, true):      return Text("Keeping Mac awake")
        default:             return Text("Sleep allowed")
        }
    }

    @ViewBuilder private var subtitle: some View {
        if let finished = model.agentsFinishedAt {
            let n = model.finishedSessions.count + model.finishedProcesses.count
            (Text(n == 1 ? "Agent finished " : "Agents finished ") + Text(finished, style: .timer) + Text(" ago")).monospacedDigit()
        } else if model.mode == .off {
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

/// The wind-down's time left, running down clockwise from 12 o'clock around the status icon.
private struct WindDownRing: View {
    let level: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: level)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 3), value: level)   // the model ticks every 3 s
        }
        .padding(-4)
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

// MARK: - Activity

private struct ActivitySection: View {
    @EnvironmentObject private var model: VigilModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                SectionLabel(title: "Activity")
                Spacer(minLength: 8)
                ConnectionStatus()
            }
            if model.isWindingDown {
                ForEach(model.finishedSessions) { SessionRow(session: $0, finished: true) }
                ForEach(model.finishedProcesses, id: \.self) { ProcessRow(name: $0, finished: true) }
            } else if model.sessions.isEmpty && model.processes.isEmpty {
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

/// Which agents are connected, right above the sessions they report: logo, name and a green dot,
/// or a gray logo with a Connect link. Codex only shows up once it's installed.
private struct ConnectionStatus: View {
    @EnvironmentObject private var model: VigilModel

    var body: some View {
        let codexMissing = model.codexAvailable && !model.codexHooksInstalled
        let bothMissing = !model.hooksInstalled && codexMissing
        HStack(spacing: 10) {
            agent("Claude Code", codex: false, connected: model.hooksInstalled, short: bothMissing, connect: model.installHooks)
            if model.codexHooksInstalled || model.codexAvailable {
                agent("Codex", codex: true, connected: model.codexHooksInstalled, short: bothMissing, connect: model.installCodexHooks)
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }

    @ViewBuilder
    private func agent(_ name: String, codex: Bool, connected: Bool, short: Bool, connect: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            AgentIcon(codex: codex, size: 12, dimmed: !connected)
            if connected {
                Text(name).foregroundStyle(.secondary)
                Circle().fill(Color.green).frame(width: 5, height: 5)
            } else {
                Button(short ? "Connect" : "Connect \(name)", action: connect)
                    .buttonStyle(.link)
            }
        }
        .help(connected
              ? "\(name) connected: Vigil sees when it's working"
              : "Connect \(name) so Vigil keeps the Mac awake exactly while it works")
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var model: VigilModel
    let session: SessionRecord
    var finished = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(codex: isCodex)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text((isCodex ? "Codex" : "Claude") + " · " + (session.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if finished {
                DoneLabel()
            } else if hovering {
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering && !finished ? 0.08 : 0.04)))
        .opacity(finished ? 0.5 : 1)
        .onHover { hovering = $0 }
    }

    private var isCodex: Bool { session.agent == "codex" }
}

/// "✓ Done" on a row that finished, shown during the wind-down.
private struct DoneLabel: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark").foregroundStyle(.green)
            Text("Done")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The agent's logo on a rounded tile, like a tiny app icon: Claude's starburst on orange,
/// the OpenAI mark on white for Codex. Fixed colors, so it reads the same in light and dark.
private struct AgentIcon: View {
    let codex: Bool
    var size: CGFloat = 20
    /// Gray and faded: the agent isn't connected.
    var dimmed = false

    private static let claudeOrange = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    private static let claudeGlyph = glyph("claude")
    private static let openAIGlyph = glyph("openai")

    /// Vector PDFs from Resources/AgentIcons, used as templates so SwiftUI can color them.
    private static func glyph(_ name: String) -> NSImage? {
        let image = Bundle.main.image(forResource: name)
        image?.isTemplate = true
        return image
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4, style: .continuous)
        shape
            .fill(codex ? Color.white : Self.claudeOrange)
            .overlay(shape.strokeBorder(Color.black.opacity(codex ? 0.12 : 0), lineWidth: 0.5))
            .overlay {
                if let glyph = codex ? Self.openAIGlyph : Self.claudeGlyph {
                    Image(nsImage: glyph).resizable().scaledToFit().padding(size * 0.15)
                } else {
                    Image(systemName: "sparkle").font(.system(size: size / 2, weight: .semibold))   // dev builds without Resources
                }
            }
            .foregroundStyle(codex ? Color.black : Color.white)
            .frame(width: size, height: size)
            .grayscale(dimmed ? 1 : 0)
            .opacity(dimmed ? 0.45 : 1)
    }
}

private struct ProcessRow: View {
    let name: String
    var finished = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium)).lineLimit(1)
                Text(finished ? "Process ended" : "Process running").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if finished {
                DoneLabel()
            } else {
                Circle().fill(Color.green).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .opacity(finished ? 0.5 : 1)
    }
}

// MARK: - Settings

private struct SettingsSection: View {
    @EnvironmentObject private var model: VigilModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Settings")
            HStack {
                Text("Stay awake after agents finish").font(.callout)
                Spacer()
                Picker("Stay awake after agents finish", selection: $model.graceMinutes) {
                    ForEach(VigilModel.graceOptions, id: \.self) { Text($0 == 0 ? "Off" : "\($0) min").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            .help("In Auto, wait this long after the last agent finishes before letting the Mac sleep")
            SettingToggle(title: "Keep display on", isOn: $model.keepDisplayAwake)
            VStack(alignment: .leading, spacing: 2) {
                SettingToggle(title: "Stay awake with lid closed", isOn: Binding(
                    get: { model.stayAwakeWithLidClosed },
                    set: { model.setStayAwakeWithLidClosed($0) }
                ))
                if model.stayAwakeWithLidClosed {
                    if let pause = model.lidPause {
                        Text(pause.reason).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Only while an agent works, or in Always and Timer").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
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
            HStack(spacing: 6) {
                AppLogo()
                Text("Vigil").font(.callout.weight(.semibold))
                Text("v\(version)").foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                if model.hooksInstalled {
                    Button("Disconnect Claude Code") { model.removeHooks() }
                } else {
                    Button("Connect Claude Code") { model.installHooks() }
                }
                if model.codexHooksInstalled {
                    Button("Disconnect Codex") { model.removeCodexHooks() }
                } else if model.codexAvailable {
                    Button("Connect Codex") { model.installCodexHooks() }
                }
                if model.lidPermissionInstalled {
                    Button("Remove Lid Permission") { model.removeLidPermission() }
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

/// The app icon, cropped to its rounded square: macOS icons carry a transparent margin that
/// would make it look smaller than the text beside it.
private struct AppLogo: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 17, height: 17)
            .frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
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
