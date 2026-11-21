import Foundation
import IOKit
import IOKit.ps

/// Keeps a Mac awake with the lid closed. No power assertion can stop clamshell sleep, so this
/// flips the system-wide `pmset -a disablesleep` — only while Vigil is keeping the Mac awake.
///
/// `pmset` needs root. A one-time admin prompt installs a sudoers rule that lets this user run
/// exactly the two `disablesleep` commands without a password, and nothing else.
final class LidGuard {
    static let sudoersPath = "/etc/sudoers.d/vigil"
    private static let pmset = "/usr/bin/pmset"

    /// Below this charge on battery, the override is dropped: a closed laptop in a bag shouldn't drain.
    static let minimumBattery = 20

    enum Pause: Equatable {
        case lowBattery, hot
        var reason: String {
            switch self {
            case .lowBattery: return "Paused: battery below \(LidGuard.minimumBattery)%"
            case .hot:        return "Paused: Mac is running hot"
            }
        }
    }

    /// Whether Vigil set `disablesleep 1` and hasn't undone it yet. Persisted, so a crash is
    /// cleaned up at the next launch — without touching a `disablesleep` the user set themselves.
    private(set) var isApplied: Bool {
        get { UserDefaults.standard.bool(forKey: "lidOverrideApplied") }
        set { UserDefaults.standard.set(newValue, forKey: "lidOverrideApplied") }
    }

    init() {
        if isApplied { set(false) }
    }

    /// Whether the sudoers rule lets this user run `pmset -a disablesleep` without a password.
    var isAuthorized: Bool {
        run("/usr/bin/sudo", ["-n", "-l", Self.pmset, "-a", "disablesleep", "1"])
    }

    /// Admin prompt → validated sudoers rule. False if the user cancels or it fails.
    func authorize() -> Bool {
        let user = NSUserName()
        guard user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmset) -a disablesleep 0, \(Self.pmset) -a disablesleep 1\n"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vigil-sudoers")
        guard (try? rule.write(to: temp, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: temp) }

        let script = "/usr/sbin/visudo -cf '\(temp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(temp.path)' \(Self.sudoersPath)"
        return runAsAdmin(script, prompt: "Vigil wants to keep your Mac awake with the lid closed.") && isAuthorized
    }

    /// Admin prompt → removes the sudoers rule (turning the override off first).
    func deauthorize() -> Bool {
        set(false)
        return runAsAdmin("/bin/rm -f \(Self.sudoersPath)", prompt: "Vigil wants to remove its lid-closed permission.")
    }

    /// Why the override shouldn't apply right now, or nil if it's safe.
    var pause: Pause? {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .hot }
        if let charge = Self.batteryOnlyCharge(), charge < Self.minimumBattery { return .lowBattery }
        return nil
    }

    /// Applies or undoes the override. Undoing it while the lid is shut puts the Mac to sleep
    /// right away: the agent is done, and the user closed the lid expecting it to sleep.
    /// False if `sudo` refused (the sudoers rule is gone) — the caller should stop asking.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        guard on != isApplied else { return true }
        guard run("/usr/bin/sudo", ["-n", Self.pmset, "-a", "disablesleep", on ? "1" : "0"]) else { return false }
        isApplied = on
        if !on && Self.lidClosedAndShouldSleep() {
            run(Self.pmset, ["sleepnow"])
        }
        return true
    }

    // MARK: Helpers

    /// Battery charge in percent while running on battery; nil on AC power or without a battery.
    private static func batteryOnlyCharge() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    /// Lid shut and macOS would normally sleep for it (not clamshell mode with an external display).
    private static func lidClosedAndShouldSleep() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        func flag(_ key: String) -> Bool {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool) ?? false
        }
        return flag("AppleClamshellState") && flag("AppleClamshellCausesSleep")
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Runs a shell command as root behind the standard macOS admin password prompt.
    private func runAsAdmin(_ command: String, prompt: String) -> Bool {
        let escaped = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = "do shell script \"\(escaped(command))\" with prompt \"\(escaped(prompt))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }
}
