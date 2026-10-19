import Foundation

/// Fallback for agents without hooks (Codex, Aider, local models…):
/// a pattern counts as active while a running command line names it as a
/// program or argument — e.g. `codex`, `node …/bin/codex`, `ollama runner`.
enum ProcessWatcher {
    static func matches(_ patterns: [String]) -> [String] {
        guard !patterns.isEmpty else { return [] }

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        let me = getpid()
        let needles = patterns.map { ($0, $0.lowercased().split(separator: " ").map(String.init)) }
        var found = Set<String>()

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<space]), pid != me else { continue }
            let command = trimmed[space...].lowercased()
            if command.contains("vigil.app") { continue }
            let words = basenames(command)
            if words.contains(where: serverSubcommands.contains) { continue }
            for (original, needle) in needles where !needle.isEmpty && contains(words, needle) {
                found.insert(original)
            }
        }
        return patterns.filter(found.contains)
    }

    /// Long-lived servers that integrations keep open while idle aren't an agent
    /// at work — e.g. the VS Code ChatGPT extension's `codex -c … app-server`, or
    /// the one the Claude Code Codex plugin's broker keeps for the whole session.
    private static let serverSubcommands: Set<String> = ["app-server", "mcp-server"]

    /// Each argument reduced to its last path component, so a pattern matches a
    /// program name but not a directory on another program's path — e.g. the
    /// Claude Code Codex plugin's hooks run as
    /// `node ~/.claude/plugins/cache/openai-codex/codex/…/hook.mjs`.
    private static func basenames(_ command: String) -> [String] {
        command.split(separator: " ").map { arg in
            String(arg.split(separator: "/").last ?? arg)
        }
    }

    private static func contains(_ words: [String], _ needle: [String]) -> Bool {
        guard words.count >= needle.count else { return false }
        return (0...(words.count - needle.count)).contains { i in
            Array(words[i..<(i + needle.count)]) == needle
        }
    }
}
