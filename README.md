# Vigil

Menu-bar app that keeps your Mac awake while an AI agent is working, and lets it sleep the moment it's done.

## Build & install

```bash
chmod +x build.sh && ./build.sh
rm -rf /Applications/Vigil.app && cp -R build/Vigil.app /Applications/ && open /Applications/Vigil.app
```

On first launch, click **Install Claude Code Hooks**. Already-open Claude Code sessions pick up hooks on restart.
Install from `/Applications` first — hooks point at the app's path. If you move it, reinstall hooks from the menu.

## Share (signed DMG)

`./release.sh` builds a universal app, signs it with your Developer ID, packs `build/Vigil-<version>.dmg`, notarizes and staples it. The version lives in `build.sh` (`VERSION=`).
One-time setup — create an app-specific password at appleid.apple.com, then:

```bash
xcrun notarytool store-credentials vigil-notary --apple-id <your Apple ID> --team-id W898QUYB63
```

## Auto-update

[Sparkle](https://sparkle-project.org) checks once a day for `appcast.xml` on the latest release of [okiro/vigil](https://github.com/okiro/vigil/releases) (`FEED_URL` in `build.sh`; the repo must be public). An update found in the background shows up as a banner in the panel; one found right after launch opens Sparkle's window. The ⋯ menu has **Check for Updates…** and **Check Automatically**.

To ship one: bump `VERSION` in `build.sh`, commit and push, then `./release.sh --publish`. It builds the notarized DMG, writes `build/appcast.xml` signed with the Sparkle key, and creates GitHub release `v<version>` with both attached.

The Sparkle signing key (EdDSA) lives in the login keychain; its public half is `SPARKLE_PUBLIC_KEY` in `build.sh`. Installed copies only accept updates signed with it, so back it up:

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key   # export; store somewhere safe, then delete the file
.build/artifacts/sparkle/Sparkle/bin/generate_keys -f sparkle-private-key   # import on another Mac
```

## How it detects "AI is working"

| Source | Signal | Precision |
|---|---|---|
| Claude Code hooks | `UserPromptSubmit` → awake, `Stop` / `StopFailure` (API error) / `SessionEnd` → release (`Stop` holds while background agents or workflows still run — their report starts a new turn) | Exact, per session |
| Process watch | Any command line naming a pattern as a program or argument, ignoring directories in paths and idle servers (`app-server`, `mcp-server` — e.g. the VS Code Codex extension or the Claude Code Codex plugin) (default: `codex`, `aider`, `ollama runner`) | Coarse: "running" ≠ "working" |

Safety nets for Claude sessions: a session is dropped if its Claude process exits, or 6 h after its last prompt (covers Esc-interrupted turns, where `Stop` doesn't fire). You can also click a session in the menu to release it.

Add `claude` to watched processes if you want "any open Claude Code = awake" instead of per-turn precision.

## UI

Click the menu-bar cup to open the panel: live status, Auto / Always / Off, active sessions (hover → ✕ to release), watched-process chips, settings.

Menu-bar icon: outlined cup = idle, filled cup = awake, number = 2+ agents working, ∞ = Always mode, moon = Off.
Light/Dark follows macOS appearance automatically (semantic colors only).

## Mechanism

A single IOKit power assertion (what `caffeinate` uses), released automatically if Vigil crashes or quits.
- Default: `PreventUserIdleSystemSleep` — screen can turn off and lock, work continues.
- **Keep Display Awake**: `PreventUserIdleDisplaySleep`.

Verify: `pmset -g assertions | grep Vigil`

## Limits

- **Closing the lid sleeps the Mac anyway** (unless on power with an external display). No user-space assertion can stop clamshell sleep; the only override is `sudo pmset -a disablesleep 1`, which Vigil deliberately doesn't touch.
- Hook config lives in `~/.claude/settings.json`; a backup is written to `settings.json.vigil-backup` on every change.

## Files

- `~/Library/Application Support/Vigil/sessions/*.json` — one file per active Claude turn
- `Sources/Vigil/` — `SleepGuard` (assertion), `Hook` (hook entry point), `SessionStore`, `ProcessWatcher`, `HookInstaller`, `VigilModel` (state), `Updater` (Sparkle), `VigilApp` + `PanelView` (SwiftUI UI)
