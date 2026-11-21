import Foundation
import Darwin

/// Entry point for Claude Code and Codex hooks. Must never block or fail the agent: always exits 0, prints nothing.
enum Hook {
    static func run(_ action: String, agent: String?) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
        let owner = ownerPID()
        let id = (json["session_id"] as? String) ?? "pid-\(owner)"

        switch action {
        case "start":
            let cwd = (json["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
            SessionStore.save(SessionRecord(id: id, pid: owner, cwd: cwd, started: Date(), agent: agent))
        case "stop":
            // A turn that hands off to background work ends with `Stop` while it runs on;
            // keep the session — its report wakes Claude for a new turn that ends with its own `Stop`.
            // (Codex's `Stop` has no `background_tasks`, so it always releases.)
            if json["hook_event_name"] as? String == "Stop" && backgroundWorkRunning(json) { break }
            SessionStore.remove(id)
        default:
            break
        }
        exit(0)
    }

    /// Any in-flight entry in `Stop`'s `background_tasks`: agents, workflows, shells, monitors.
    /// A shell that never finishes (a dev server) holds the session until Claude exits, the
    /// 6 h safety net, or the user releases it from the menu.
    static func backgroundWorkRunning(_ json: [String: Any]) -> Bool {
        let tasks = json["background_tasks"] as? [[String: Any]] ?? []
        return tasks.contains { ["running", "pending"].contains($0["status"] as? String ?? "") }
    }

    /// The agent process that spawned this hook, skipping any intermediate shells.
    static func ownerPID() -> pid_t {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env"]
        var pid = getppid()
        for _ in 0..<5 {
            guard let info = processInfo(pid), shells.contains(info.name), info.ppid > 1 else { break }
            pid = info.ppid
        }
        return pid
    }

    static func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let raw = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-"))  // login shells: "-zsh"
        return (info.kp_eproc.e_ppid, name)
    }
}
