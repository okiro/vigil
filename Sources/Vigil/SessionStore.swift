import Foundation
import Darwin

/// One active Claude Code turn. Written by the hook, read by the app.
struct SessionRecord: Codable, Equatable, Identifiable {
    var id: String
    var pid: Int32        // the Claude Code process that owns the session
    var cwd: String
    var started: Date     // last prompt submitted
}

enum SessionStore {
    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Vigil/sessions", isDirectory: true)

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func url(for id: String) -> URL {
        directory.appendingPathComponent(sanitize(id) + ".json")
    }

    static func save(_ record: SessionRecord) {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: url(for: record.id), options: .atomic)
        }
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Sessions whose owning process is still alive and that aren't older than `maxAge`.
    /// Dead or stale records are deleted (covers crashes and Esc-interrupted turns).
    static func liveSessions(maxAge: TimeInterval) -> [SessionRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var live: [SessionRecord] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(SessionRecord.self, from: data) else {
                try? fm.removeItem(at: file)
                continue
            }
            let alive = record.pid > 1 && (kill(record.pid, 0) == 0 || errno == EPERM)
            let fresh = maxAge <= 0 || Date().timeIntervalSince(record.started) < maxAge
            if alive && fresh {
                live.append(record)
            } else {
                try? fm.removeItem(at: file)
            }
        }
        return live.sorted { $0.started < $1.started }
    }

    private static func sanitize(_ s: String) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        })
        let clean = String(String(view).prefix(128))
        return clean.isEmpty ? "unknown" : clean
    }
}
