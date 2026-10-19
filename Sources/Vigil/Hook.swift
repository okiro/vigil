import Foundation
import Darwin

/// Entry point for Claude Code hooks. Must never block or fail Claude: always exits 0, prints nothing.
enum Hook {
    static func run(_ action: String) -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = ((try? JSONSerialization.jsonObject(with: input)) as? [String: Any]) ?? [:]
        let owner = ownerPID()
        let id = (json["session_id"] as? String) ?? "pid-\(owner)"

        switch action {
        case "start":
            let cwd = (json["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
            SessionStore.save(SessionRecord(id: id, pid: owner, cwd: cwd, started: Date()))
        case "stop":
            // A turn that hands off to background agents ends with `Stop` while they work on;
            // keep the session — their report wakes Claude for a new turn that ends with its own `Stop`.
            if json["hook_event_name"] as? String == "Stop" && agentsRunning(json) { break }
            SessionStore.remove(id)
        default:
            break
        }
        exit(0)
    }

    /// Background work in `Stop`'s `background_tasks` that is agents thinking on this Mac. Shells
    /// and monitors are left out: they're often idle servers or watchers that never finish.
    static func agentsRunning(_ json: [String: Any]) -> Bool {
        let tasks = json["background_tasks"] as? [[String: Any]] ?? []
        return tasks.contains { task in
            ["subagent", "workflow"].contains(task["type"] as? String ?? "")
                && ["running", "pending"].contains(task["status"] as? String ?? "")
        }
    }

    /// The Claude Code process that spawned this hook, skipping any intermediate shells.
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
