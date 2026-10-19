import SwiftUI

// `Vigil hook start|stop` is called by Claude Code hooks: record state and exit fast.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "hook" {
    Hook.run(args[2])
}

VigilApp.main()
