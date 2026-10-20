# Vigil

Menu-bar app that keeps your Mac awake while an AI agent is working, and lets it sleep the moment it's done.

## Build & install

```bash
chmod +x build.sh && ./build.sh
rm -rf /Applications/Vigil.app && cp -R build/Vigil.app /Applications/ && open /Applications/Vigil.app
```

On first launch, click **Install Claude Code Hooks**. Already-open Claude Code sessions pick up hooks on restart.
Install from `/Applications` first — hooks point at the app's path. If you move it, reinstall hooks from the menu.

## Releases & auto-update

Every push to `main` that changes the app ships a new version: [the Release workflow](.github/workflows/release.yml) builds a universal app, signs it with the Developer ID, notarizes `Vigil-<version>.dmg`, and publishes it as GitHub release `v<version>` with a Sparkle `appcast.xml`. Pushes that only touch Markdown don't release.

The version comes from the commit messages since the last `v*` tag ([Conventional Commits](https://www.conventionalcommits.org)):

| Commit | Bump | Example |
|---|---|---|
| `feat!: …`, or a `BREAKING CHANGE:` line in the body | major | 0.4.2 → 1.0.0 |
| `feat: …` / `feat(scope): …` | minor | 0.4.2 → 0.5.0 |
| anything else (`fix: …`, `chore: …`, no prefix) | patch | 0.4.2 → 0.4.3 |

Installed copies check [okiro/vigil](https://github.com/okiro/vigil/releases)'s latest release once a day ([Sparkle](https://sparkle-project.org); `FEED_URL` in `build.sh`, the repo must be public), download updates in the background, and install them as soon as Vigil isn't keeping the Mac awake — the relaunch takes a second, and dropping the power assertion mid-run could let an idle Mac sleep. In **Always** mode that means at the next quit. The ⋯ menu has **Check for Updates…** and **Update Automatically**.

### One-time CI setup

The workflow needs five repository secrets (`gh secret set NAME` prompts for the value, keeping it out of shell history):

```bash
# Sparkle key: export it, keep the file in your password manager (it's also your backup), then upload
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key && rm sparkle-private-key

# Developer ID: Keychain Access → My Certificates → "Developer ID Application: …" → Export… as developer-id.p12
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12 && rm developer-id.p12
gh secret set DEVELOPER_ID_P12_PASSWORD    # the password you chose when exporting

# Notarization: an app-specific password from appleid.apple.com
gh secret set APPLE_ID
gh secret set APPLE_APP_PASSWORD
```

Installed copies only accept updates signed with that Sparkle key (public half: `SPARKLE_PUBLIC_KEY` in `build.sh`). Lose it and everyone has to reinstall by hand. `generate_keys -f sparkle-private-key` imports it on another Mac.

### Releasing from this Mac

`./release.sh` builds the next version's notarized DMG and appcast locally; `--publish` also creates the GitHub release (CI normally does this). It uses the keychain: the Sparkle key, the Developer ID, and a notarization profile stored once with:

```bash
xcrun notarytool store-credentials vigil-notary --apple-id <your Apple ID> --team-id W898QUYB63
```

## How it detects "AI is working"

| Source | Signal | Precision |
|---|---|---|
| Claude Code hooks | `UserPromptSubmit` → awake, `Stop` / `StopFailure` (API error) / `SessionEnd` → release (`Stop` holds while background agents or workflows still run — their report starts a new turn) | Exact, per session |
| Process watch | Any command line naming a pattern as a program or argument, ignoring directories in paths and idle servers (`app-server`, `mcp-server` — e.g. the VS Code Codex extension or the Claude Code Codex plugin) (default: `codex`, `aider`, `ollama runner`) | Coarse: "running" ≠ "working" |

Safety nets for Claude sessions: a session is dropped if its Claude process exits, or 6 h after its last prompt (covers Esc-interrupted turns, where `Stop` doesn't fire). You can also click a session in the menu to release it.

Add `claude` to watched processes if you want "any open Claude Code = awake" instead of per-turn precision.

## UI

Click the menu-bar cup to open the panel: live status, Auto / Always / Off / Timer (stay awake for 30 min – 8 h, then back to Auto, or Off if it was off), active sessions (hover → ✕ to release), watched-process chips, settings.

Menu-bar icon: outlined cup = idle, filled cup = awake, number = 2+ agents working, ∞ = Always mode, 1:59 = time left on a timer, moon = Off.
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
