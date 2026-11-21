import SwiftUI

// `Vigil hook start|stop [codex]` is called by Claude Code and Codex hooks: record state and exit fast.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "hook" {
    Hook.run(args[2], agent: args.count >= 4 ? args[3] : nil)
}

VigilApp.main()
