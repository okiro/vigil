import Foundation

/// Adds/removes Vigil's hooks in ~/.claude/settings.json without touching anything else.
enum HookInstaller {
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private static let events: [(event: String, action: String)] = [
        ("UserPromptSubmit", "start"),
        ("Stop", "stop"),
        ("StopFailure", "stop"),   // fires instead of `Stop` when an API error ends the turn
        ("SessionEnd", "stop"),
    ]

    enum InstallError: LocalizedError {
        case unreadable
        var errorDescription: String? {
            "~/.claude/settings.json exists but isn't valid JSON. Fix it and try again — Vigil won't overwrite it."
        }
    }

    static func command(_ action: String) -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "'\(exe)' hook \(action)"
    }

    /// True only if every hook points at *this* copy of the app (moving the app → reinstall).
    static var isInstalled: Bool {
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

    static func install() throws { try modify(adding: true) }
    static func uninstall() throws { try modify(adding: false) }

    private static func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw InstallError.unreadable
        }
        return obj
    }

    private static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let cmd = hook["command"] as? String else { return false }
        return cmd.contains("/Vigil'") && cmd.contains(" hook ")
    }

    private static func modify(adding: Bool) throws {
        var root = try load()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for entry in events {
            var groups: [[String: Any]] = (hooks[entry.event] as? [[String: Any]] ?? []).compactMap { group in
                let original = group["hooks"] as? [[String: Any]] ?? []
                let kept = original.filter { !isOurs($0) }
                if kept.isEmpty && !original.isEmpty { return nil }   // group was only ours
                var g = group
                g["hooks"] = kept
                return g
            }
            if adding {
                groups.append(["hooks": [["type": "command", "command": command(entry.action), "timeout": 5]]])
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
