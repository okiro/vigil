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
        static let watch = "watchProcesses"
        static let patterns = "processPatterns"
        static let staleHours = "staleHours"
        static let askedHooks = "askedHooks"
        static let timerEnd = "timerEnd"
        static let timerMinutes = "timerMinutes"
        static let modeAfterTimer = "modeAfterTimer"
    }

    /// Lengths offered by the Timer segment's dropdown, in minutes.
    static let timerOptions = [30, 60, 120, 240, 480]

    // Live state
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var processes: [String] = []
    @Published private(set) var isActive = false
    @Published private(set) var awakeSince: Date?
    /// Rounded up, so the menu-bar countdown reads 0:01 in the last minute, not 0:00.
    @Published private(set) var minutesLeft = 0
    @Published private(set) var hooksInstalled = false
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
    @Published var watchProcesses: Bool {
        didSet { defaults.set(watchProcesses, forKey: Key.watch); tick() }
    }
    @Published private(set) var patterns: [String] {
        didSet { defaults.set(patterns, forKey: Key.patterns); tick() }
    }

    let updater = Updater()

    private let defaults = UserDefaults.standard
    private let sleepGuard = SleepGuard()
    private var timer: Timer?

    override init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Key.mode: Mode.automatic.rawValue,
            Key.display: false,
            Key.watch: true,
            Key.patterns: ["codex", "aider", "ollama runner"],
            Key.staleHours: 6.0,
            Key.timerMinutes: 60,
            Key.modeAfterTimer: Mode.automatic.rawValue,
        ])
        mode = Mode(rawValue: d.integer(forKey: Key.mode)) ?? .automatic
        timerEnd = d.object(forKey: Key.timerEnd) as? Date
        timerMinutes = d.integer(forKey: Key.timerMinutes)
        keepDisplayAwake = d.bool(forKey: Key.display)
        watchProcesses = d.bool(forKey: Key.watch)
        patterns = d.stringArray(forKey: Key.patterns) ?? []
        super.init()

        SessionStore.ensureDirectory()
        refreshStatus()
        tick()
        timer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer?.tolerance = 1

        if !hooksInstalled && !d.bool(forKey: Key.askedHooks) {
            d.set(true, forKey: Key.askedHooks)
            perform(#selector(offerHookInstall), with: nil, afterDelay: 1)
        }
    }

    // MARK: Derived

    var activeCount: Int { sessions.count + processes.count }

    var menuIcon: String {
        if mode == .off { return "moon.zzz" }
        return isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
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
        if mode == .timed, (timerEnd ?? .distantPast) <= Date() {
            mode = Mode(rawValue: defaults.integer(forKey: Key.modeAfterTimer)) ?? .automatic  // ticks again
            return
        }
        let left = timerEnd.map { Int(($0.timeIntervalSinceNow / 60).rounded(.up)) } ?? 0
        if left != minutesLeft { minutesLeft = left }

        let newSessions = SessionStore.liveSessions(maxAge: defaults.double(forKey: Key.staleHours) * 3600)
        let newProcesses = (mode == .automatic && watchProcesses) ? ProcessWatcher.matches(patterns) : []
        if newSessions != sessions { sessions = newSessions }
        if newProcesses != processes { processes = newProcesses }

        let active: Bool
        switch mode {
        case .automatic:        active = !newSessions.isEmpty || !newProcesses.isEmpty
        case .alwaysOn, .timed: active = true
        case .off:              active = false
        }
        if active != isActive {
            isActive = active
            awakeSince = active ? Date() : nil
        }
        sleepGuard.update(active: active, display: keepDisplayAwake)
        if !active { updater.installDownloadedUpdate() }
    }

    func refreshStatus() {
        hooksInstalled = HookInstaller.isInstalled
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
        do { try HookInstaller.install(); errorMessage = nil } catch { errorMessage = error.localizedDescription }
        refreshStatus()
    }

    func removeHooks() {
        do { try HookInstaller.uninstall() } catch { errorMessage = error.localizedDescription }
        refreshStatus()
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
