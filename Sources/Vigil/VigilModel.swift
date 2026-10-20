import AppKit
import SwiftUI
import ServiceManagement

enum Mode: Int, CaseIterable, Identifiable {
    case automatic = 0, alwaysOn = 1, off = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .alwaysOn:  return "Always"
        case .off:       return "Off"
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
    }

    // Live state
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var processes: [String] = []
    @Published private(set) var isActive = false
    @Published private(set) var awakeSince: Date?
    @Published private(set) var hooksInstalled = false
    @Published private(set) var launchAtLogin = false
    @Published var errorMessage: String?

    // Settings (persisted)
    @Published var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode); tick() }
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
        ])
        mode = Mode(rawValue: d.integer(forKey: Key.mode)) ?? .automatic
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

    /// ∞ when forced on; a number only from 2 agents up (the filled cup already says "1").
    var menuBadge: String? {
        switch mode {
        case .alwaysOn:  return "∞"
        case .automatic: return activeCount >= 2 ? "\(activeCount)" : nil
        case .off:       return nil
        }
    }

    // MARK: Polling

    @objc func tick() {
        let newSessions = SessionStore.liveSessions(maxAge: defaults.double(forKey: Key.staleHours) * 3600)
        let newProcesses = (mode == .automatic && watchProcesses) ? ProcessWatcher.matches(patterns) : []
        if newSessions != sessions { sessions = newSessions }
        if newProcesses != processes { processes = newProcesses }

        let active: Bool
        switch mode {
        case .automatic: active = !newSessions.isEmpty || !newProcesses.isEmpty
        case .alwaysOn:  active = true
        case .off:       active = false
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
