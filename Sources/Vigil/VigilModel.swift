import AppKit
import SwiftUI
import ServiceManagement

enum Mode: Int, CaseIterable, Identifiable {
    case automatic = 0, alwaysOn = 1, off = 2, timed = 3
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .alwaysOn:  return "Always"
        case .off:       return "Off"
        case .timed:     return "Timer"
        }
    }
}

@MainActor
final class VigilModel: NSObject, ObservableObject {
    private enum Key {
        static let mode = "mode"
        static let display = "keepDisplayAwake"
        static let lid = "stayAwakeWithLidClosed"
        static let watch = "watchProcesses"
        static let patterns = "processPatterns"
        static let staleHours = "staleHours"
        static let askedHooks = "askedHooks"
        static let timerEnd = "timerEnd"
        static let timerMinutes = "timerMinutes"
        static let modeAfterTimer = "modeAfterTimer"
        static let graceMinutes = "graceMinutes"
    }

    /// Lengths offered by the Timer segment's dropdown, in minutes.
    static let timerOptions = [30, 60, 120, 240, 480]
    /// Lengths offered for "Stay awake after agents finish", in minutes (0 = off).
    static let graceOptions = [0, 1, 2, 5, 10, 15]

    // Live state
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var processes: [String] = []
    @Published private(set) var isActive = false
    @Published private(set) var awakeSince: Date?
    /// Auto mode's wind-down: after the last agent finishes, the Mac stays awake until this moment.
    @Published private(set) var windDownEnd: Date?
    /// What was working when the wind-down started, shown dimmed as "Done" until it ends.
    @Published private(set) var finishedSessions: [SessionRecord] = []
    @Published private(set) var finishedProcesses: [String] = []
    /// Share of the wind-down still left, 1 → 0, in steps of 1%; drives the draining cup and ring.
    @Published private(set) var windDownLevel: Double = 0
    /// Rounded up, so the menu-bar countdown reads 0:01 in the last minute, not 0:00.
    @Published private(set) var minutesLeft = 0
    @Published private(set) var hooksInstalled = false
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var codexAvailable = false
    /// Why the lid-closed override is paused while Vigil is otherwise keeping the Mac awake.
    @Published private(set) var lidPause: LidGuard.Pause?
    @Published private(set) var launchAtLogin = false
    @Published var errorMessage: String?

    // Settings (persisted)
    @Published var mode: Mode {
        didSet {
            defaults.set(mode.rawValue, forKey: Key.mode)
            if mode != .timed { timerEnd = nil }
            tick()
        }
    }
    /// Timer mode keeps the Mac awake until this moment, then goes back to the mode before it.
    @Published private(set) var timerEnd: Date? {
        didSet { defaults.set(timerEnd, forKey: Key.timerEnd) }
    }
    @Published private(set) var timerMinutes: Int {
        didSet { defaults.set(timerMinutes, forKey: Key.timerMinutes) }
    }
    @Published var keepDisplayAwake: Bool {
        didSet { defaults.set(keepDisplayAwake, forKey: Key.display); tick() }
    }
    /// Set through `setStayAwakeWithLidClosed`, which asks for admin rights the first time.
    @Published private(set) var stayAwakeWithLidClosed: Bool {
        didSet { defaults.set(stayAwakeWithLidClosed, forKey: Key.lid); tick() }
    }
    @Published var watchProcesses: Bool {
        didSet { defaults.set(watchProcesses, forKey: Key.watch); tick() }
    }
    @Published private(set) var patterns: [String] {
        didSet { defaults.set(patterns, forKey: Key.patterns); tick() }
    }
    /// How long Auto keeps the Mac awake after the last agent finishes. 0 lets it sleep right away.
    @Published var graceMinutes: Int {
        didSet {
            defaults.set(graceMinutes, forKey: Key.graceMinutes)
            if graceMinutes == 0 { sleepNow() }
        }
    }

    let updater = Updater()

    private let defaults = UserDefaults.standard
    private let sleepGuard = SleepGuard()
    private let lidGuard = LidGuard()
    private var timer: Timer?

    override init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.mode: Mode.automatic.rawValue,
            Key.display: false,
            Key.lid: false,
            Key.watch: true,
            Key.patterns: ["codex", "aider", "ollama runner"],
            Key.staleHours: 6.0,
            Key.timerMinutes: 60,
            Key.modeAfterTimer: Mode.automatic.rawValue,
            Key.graceMinutes: 5,
        ])
        mode = Mode(rawValue: d.integer(forKey: Key.mode)) ?? .automatic
        timerEnd = d.object(forKey: Key.timerEnd) as? Date
        timerMinutes = d.integer(forKey: Key.timerMinutes)
        keepDisplayAwake = d.bool(forKey: Key.display)
        stayAwakeWithLidClosed = d.bool(forKey: Key.lid)
        watchProcesses = d.bool(forKey: Key.watch)
        patterns = d.stringArray(forKey: Key.patterns) ?? []
        graceMinutes = d.integer(forKey: Key.graceMinutes)
        super.init()

        SessionStore.ensureDirectory()
        refreshStatus()
        tick()
        timer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer?.tolerance = 1
        // Quitting (or Sparkle relaunching for an update) must never leave sleep disabled.
        NotificationCenter.default.addObserver(
            self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil
        )

        if !hooksInstalled && !d.bool(forKey: Key.askedHooks) {
            d.set(true, forKey: Key.askedHooks)
            perform(#selector(offerHookInstall), with: nil, afterDelay: 1)
        }
    }

    // MARK: Derived

    var activeCount: Int { sessions.count + processes.count }

    var isWindingDown: Bool { windDownEnd != nil }

    /// When the last agent finished, if the Mac is winding down.
    var agentsFinishedAt: Date? {
        windDownEnd.map { $0.addingTimeInterval(-TimeInterval(windDownMinutes * 60)) }
    }

    /// The length of the current wind-down, fixed when it starts so changing the setting doesn't jump the ring.
    private var windDownMinutes = 0
    /// Releasing the last session by hand means "let it sleep", so it skips the wind-down.
    private var skipWindDown = false

    var menuIcon: String {
        if mode == .off { return "moon.zzz" }
        return isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    /// Red cup: closing the lid won't sleep the Mac — outlined while idle (armed), filled while it holds.
    /// Not when Off, and not while the override is paused for battery or heat.
    var lidArmed: Bool {
        stayAwakeWithLidClosed && mode != .off && !(isActive && lidPause != nil)
    }

    /// ∞ when forced on, h:mm left on a timer; a number only from 2 agents up (the filled cup already says "1").
    var menuBadge: String? {
        switch mode {
        case .alwaysOn:  return "∞"
        case .timed:     return String(format: "%d:%02d", minutesLeft / 60, minutesLeft % 60)
        case .automatic: return activeCount >= 2 ? "\(activeCount)" : nil
        case .off:       return nil
        }
    }

    // MARK: Polling

    @objc func tick() {
        let now = Date()
        if mode == .timed, (timerEnd ?? .distantPast) <= now {
            mode = Mode(rawValue: defaults.integer(forKey: Key.modeAfterTimer)) ?? .automatic  // ticks again
            return
        }
        let left = timerEnd.map { Int(($0.timeIntervalSinceNow / 60).rounded(.up)) } ?? 0
        if left != minutesLeft { minutesLeft = left }

        let newSessions = SessionStore.liveSessions(maxAge: defaults.double(forKey: Key.staleHours) * 3600)
        let newProcesses = (mode == .automatic && watchProcesses) ? ProcessWatcher.matches(patterns) : []
        let wasWorking = !sessions.isEmpty || !processes.isEmpty
        let working = !newSessions.isEmpty || !newProcesses.isEmpty
        updateWindDown(wasWorking: wasWorking, working: working, now: now)
        if newSessions != sessions { sessions = newSessions }
        if newProcesses != processes { processes = newProcesses }

        let active: Bool
        switch mode {
        case .automatic:        active = working || isWindingDown
        case .alwaysOn, .timed: active = true
        case .off:              active = false
        }
        if active != isActive {
            isActive = active
            awakeSince = active ? Date() : nil
        }
        sleepGuard.update(active: active, display: keepDisplayAwake)

        // Not during the wind-down: closing the lid after the agents are done should sleep the Mac.
        let holdLid = stayAwakeWithLidClosed && active && !isWindingDown
        let pause = holdLid ? lidGuard.pause : nil
        if pause != lidPause { lidPause = pause }
        if !lidGuard.set(holdLid && pause == nil) && stayAwakeWithLidClosed {
            stayAwakeWithLidClosed = false
            errorMessage = "Vigil lost permission to keep the Mac awake with the lid closed. Turn the setting on again to grant it."
        }
        if !active { updater.installDownloadedUpdate() }
    }

    /// Starts the wind-down when the last agent finishes in Auto, cancels it when one starts again,
    /// and ends it when time is up.
    private func updateWindDown(wasWorking: Bool, working: Bool, now: Date) {
        if mode != .automatic || working {
            endWindDown()
        } else if wasWorking && graceMinutes > 0 && !skipWindDown {
            windDownMinutes = graceMinutes
            finishedSessions = sessions
            finishedProcesses = processes
            windDownEnd = now.addingTimeInterval(TimeInterval(graceMinutes * 60))
        } else if let end = windDownEnd, end <= now {
            endWindDown()
        }
        let level = windDownEnd.map { end in
            (end.timeIntervalSince(now) / TimeInterval(windDownMinutes * 60) * 100).rounded(.up) / 100
        } ?? 0
        if level != windDownLevel { windDownLevel = min(max(level, 0), 1) }
    }

    private func endWindDown() {
        if windDownEnd != nil { windDownEnd = nil }
        if !finishedSessions.isEmpty { finishedSessions = [] }
        if !finishedProcesses.isEmpty { finishedProcesses = [] }
    }

    func refreshStatus() {
        hooksInstalled = HookInstaller.claude.isInstalled
        codexHooksInstalled = HookInstaller.codex.isInstalled
        codexAvailable = HookInstaller.codex.isAvailable
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Actions

    /// Picking a length again, or another one, restarts the countdown from now.
    func startTimer(minutes: Int) {
        timerMinutes = minutes
        timerEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if mode == .timed {
            tick()
        } else {
            // Always would make the timer pointless, so it comes back as Auto.
            defaults.set(mode == .off ? Mode.off.rawValue : Mode.automatic.rawValue, forKey: Key.modeAfterTimer)
            mode = .timed
        }
    }

    func release(_ id: String) {
        SessionStore.remove(id)
        skipWindDown = true
        tick()
        skipWindDown = false
    }

    /// Ends the wind-down early and lets the Mac sleep.
    func sleepNow() {
        guard isWindingDown else { return }
        endWindDown()
        tick()
    }

    func addPattern(_ raw: String) {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !patterns.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) else { return }
        patterns.append(p)
    }

    func removePattern(_ p: String) {
        patterns.removeAll { $0 == p }
    }

    func installHooks() {
        do { try HookInstaller.claude.install(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
        refreshStatus()
    }

    func removeHooks() {
        do { try HookInstaller.claude.uninstall() } catch { errorMessage = error.localizedDescription }
        refreshStatus()
    }

    /// Codex then reports each turn, so watching for a running `codex` process — which stays
    /// "running" while Codex sits idle — is dropped. Disconnecting brings it back.
    func installCodexHooks() {
        do { try HookInstaller.codex.install(); errorMessage = nil } catch { errorMessage = error.localizedDescription; return }
        refreshStatus()
        patterns.removeAll { $0.caseInsensitiveCompare("codex") == .orderedSame }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "One more step in Codex"
        alert.informativeText = "Restart any Codex sessions that are already open. If Codex says “Hooks need review”, choose “Trust all and continue” so it can tell Vigil when it's working."
        alert.runModal()
    }

    func removeCodexHooks() {
        do { try HookInstaller.codex.uninstall() } catch { errorMessage = error.localizedDescription }
        refreshStatus()
        if !codexHooksInstalled { addPattern("codex") }
    }

    /// Turning it on the first time shows the macOS admin prompt; cancelling leaves it off.
    func setStayAwakeWithLidClosed(_ on: Bool) {
        if on && !lidGuard.isAuthorized {
            NSApp.activate(ignoringOtherApps: true)
            guard lidGuard.authorize() else { return }
        }
        stayAwakeWithLidClosed = on
    }

    var lidPermissionInstalled: Bool { FileManager.default.fileExists(atPath: LidGuard.sudoersPath) }

    func removeLidPermission() {
        stayAwakeWithLidClosed = false
        if !lidGuard.deauthorize() { errorMessage = "Couldn't remove \(LidGuard.sudoersPath)." }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshStatus()
        if on && SMAppService.mainApp.status == .requiresApproval {
            errorMessage = "Allow Vigil in System Settings → General → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func openSessionsFolder() {
        NSWorkspace.shared.open(SessionStore.directory)
    }

    @objc private func willTerminate() {
        lidGuard.set(false)
    }

    @objc private func offerHookInstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Connect Vigil to Claude Code?"
        alert.informativeText = "Vigil adds four hooks to ~/.claude/settings.json so it knows exactly when Claude is working. A backup is saved as settings.json.vigil-backup."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { installHooks() }
    }
}
