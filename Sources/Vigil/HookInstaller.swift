import Foundation

/// Adds/removes Vigil's hooks in an agent's hooks file without touching anything else.
/// Claude Code and Codex share the format: `{"hooks": {"Event": [{"hooks": [{"type": "command", …}]}]}}`.
struct HookInstaller {
    let name: String
    let settingsURL: URL
    /// Passed to `Vigil hook <action> <agent>`; nil for Claude Code, whose hooks predate the argument.
    let agent: String?
    /// Seconds; Codex clamps some events to 3 and warns at every start if asked for more.
    private let timeout: Int
    private let events: [(event: String, action: String)]

    static let claude = HookInstaller(
        name: "Claude Code",
        settingsURL: home.appendingPathComponent(".claude/settings.json"),
        agent: nil,
        timeout: 5,
        events: [
            ("UserPromptSubmit", "start"),
            ("Stop", "stop"),
            ("StopFailure", "stop"),   // fires instead of `Stop` when an API error ends the turn
            ("SessionEnd", "stop"),
        ]
    )

    static let codex = HookInstaller(
        name: "Codex",
        settingsURL: home.appendingPathComponent(".codex/hooks.json"),
        agent: "codex",
        timeout: 3,
        events: [
            ("UserPromptSubmit", "start"),
            ("Stop", "stop"),
            ("Interrupt", "stop"),     // Esc ends the turn without a `Stop`
            ("SessionEnd", "stop"),
        ]
    )

    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Codex keeps its config in ~/.codex; without it there's nothing to connect.
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    enum InstallError: LocalizedError {
        case unreadable(URL)
        var errorDescription: String? {
            guard case .unreadable(let url) = self else { return nil }
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            return "\(path) exists but isn't valid JSON. Fix it and try again — Vigil won't overwrite it."
        }
    }

    func command(_ action: String) -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "'\(exe)' hook \(action)" + (agent.map { " \($0)" } ?? "")
    }

    /// True only if every hook points at *this* copy of the app (moving the app → reinstall).
    var isInstalled: Bool {
        guard let root = try? load(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { entry in
            let groups = hooks[entry.event] as? [[String: Any]] ?? []
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    $0["command"] as? String == command(entry.action)
                }
            }
        }
    }

    func install() throws { try modify(adding: true) }
    func uninstall() throws { try modify(adding: false) }

    private func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.unreadable(settingsURL)
        }
        return obj
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let cmd = hook["command"] as? String else { return false }
        return cmd.contains("/Vigil'") && cmd.contains(" hook ")
    }

    private func modify(adding: Bool) throws {
        var root = try load()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for entry in events {
            var groups: [[String: Any]] = (hooks[entry.event] as? [[String: Any]] ?? []).compactMap { group in
                let original = group["hooks"] as? [[String: Any]] ?? []
                let kept = original.filter { !Self.isOurs($0) }
                if kept.isEmpty && !original.isEmpty { return nil }   // group was only ours
                var g = group
                g["hooks"] = kept
                return g
            }
            if adding {
                groups.append(["hooks": [["type": "command", "command": command(entry.action), "timeout": timeout]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: entry.event) } else { hooks[entry.event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.appendingPathExtension("vigil-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
