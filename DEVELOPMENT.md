# Developing Vigil

Notes for building, releasing and understanding Vigil. Looking for the app? See the [README](README.md).

## Build & install

```bash
chmod +x build.sh && ./build.sh
rm -rf /Applications/Vigil.app && cp -R build/Vigil.app /Applications/ && open /Applications/Vigil.app
```

On first launch, click **Connect** (next to **Activity** in the panel) to install the Claude Code hooks. Already-open Claude Code sessions pick up hooks on restart.
Install from `/Applications` first — hooks point at the app's path. If you move it, use **Connect Claude Code** in the ⋯ menu again.

## Releases & auto-update

Every push to `main` that changes the app ships a new version: [the Release workflow](.github/workflows/release.yml) builds a universal app, signs it with the Developer ID, notarizes `Vigil-<version>.dmg`, and publishes it as GitHub release `v<version>` with a Sparkle `appcast.xml` and a copy named `Vigil.dmg` (the README's download link, `releases/latest/download/Vigil.dmg`). Pushes that only touch Markdown or `docs/` (the README screenshot) don't release.

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
| Claude Code hooks | `UserPromptSubmit` → awake, `Stop` / `StopFailure` (API error) / `SessionEnd` → release (`Stop` holds while background agents, workflows, shells or monitors still run — their report starts a new turn) | Exact, per session |
| Codex hooks (`~/.codex/hooks.json`) | `UserPromptSubmit` → awake, `Stop` / `Interrupt` (Esc) / `SessionEnd` → release. Codex shows "Hooks need review" once; cmux's Codex wrapper skips that with `--dangerously-bypass-hook-trust`. Codex clamps some hook timeouts to 3 s, so Vigil asks for 3. | Exact, per session |
| Process watch | Any command line naming a pattern as a program or argument, ignoring directories in paths and idle servers (`app-server`, `mcp-server` — e.g. the VS Code Codex extension or the Claude Code Codex plugin) (default: `codex`, `aider`, `ollama runner`; connecting Codex removes `codex`, disconnecting adds it back) | Coarse: "running" ≠ "working" |

Hooks run `Vigil hook start|stop` (Claude Code) or `Vigil hook start|stop codex`; the record's `agent` field labels the session in the panel.

Safety nets for hook sessions: a session is dropped if its agent process exits, or 6 h after its last prompt (covers Esc-interrupted turns, where `Stop` doesn't fire). You can also click a session in the menu to release it.

Add `claude` to watched processes if you want "any open Claude Code = awake" instead of per-turn precision.

## UI

Click the menu-bar cup to open the panel: live status, Auto / Always / Off / Timer (stay awake for 30 min – 8 h, then back to Auto, or Off if it was off), active sessions (hover → ✕ to release; releasing the last one skips the wind-down), which agents are connected (next to **Activity**, with Connect links), watched-process chips, settings.

Wind-down: in Auto, when the last agent finishes, the Mac stays awake for **Stay awake after agents finish** (default 5 min; `graceMinutes`), then the assertion is dropped. A new turn cancels it, **Sleep now** ends it. The lid-closed override isn't held during the wind-down, so closing the lid after the agents finish still sleeps the Mac.

Menu-bar icon: outlined cup = idle, filled cup = awake, draining cup = wind-down (`CupIcon`: `cup.and.saucer.fill` clipped to the time left, drawn over `cup.and.saucer`), number = 2+ agents working, ∞ = Always mode, 1:59 = time left on a timer, moon = Off. With **Stay awake with lid closed** on, the cup is red (a non-template image, the only way to color a menu-bar icon): outlined = armed, filled = closing the lid won't sleep the Mac right now. It goes back to the normal color while the override is paused.
Light/Dark follows macOS appearance automatically (semantic colors only).

## Mechanism

A single IOKit power assertion (what `caffeinate` uses), released automatically if Vigil crashes or quits.
- Default: `PreventUserIdleSystemSleep` — screen can turn off and lock, work continues.
- **Keep Display Awake**: `PreventUserIdleDisplaySleep`.

Verify: `pmset -g assertions | grep Vigil`

### Stay awake with lid closed

No assertion can stop clamshell sleep, so `LidGuard` sets `pmset -a disablesleep 1` (shows as `SleepDisabled 1` in `pmset -g`) — only while Vigil is keeping the Mac awake — and `0` as soon as it isn't.
- **Permission:** turning the toggle on the first time shows the macOS admin prompt, which installs `/etc/sudoers.d/vigil` (validated with `visudo -c`): this user may run exactly `/usr/bin/pmset -a disablesleep 0` and `… 1` without a password, via `sudo -n`. **Remove Lid Permission** in the ⋯ menu deletes it.
- **Never stuck on:** Vigil undoes it on quit (including Sparkle's update relaunch) and at launch if a crash left it set (`lidOverrideApplied` in its defaults; a `disablesleep` you set yourself is left alone). If Vigil crashes and isn't reopened, the Mac can't sleep until it is — `sudo pmset -a disablesleep 0` fixes it by hand.
- **Paused** (normal idle-sleep assertion stays) on battery below 20 % or at thermal state *serious*, so a laptop in a bag doesn't cook or drain.
- **Lid already shut when work ends:** after undoing the override, Vigil runs `pmset sleepnow` if `IOPMrootDomain` reports `AppleClamshellState` and `AppleClamshellCausesSleep` (not clamshell mode with an external display).

## Limits

- **Closing the lid sleeps the Mac** (unless on power with an external display) unless **Stay awake with lid closed** is on — see above.
- Hook config lives in `~/.claude/settings.json` and `~/.codex/hooks.json`; a `.vigil-backup` copy is written next to each on every change.

## Files

- `~/Library/Application Support/Vigil/sessions/*.json` — one file per active Claude Code or Codex turn
- `Resources/AgentIcons/` — Claude and OpenAI logos for session rows (Lobe Icons, MIT; vector PDFs, see its README)
- `Sources/Vigil/` — `SleepGuard` (assertion), `LidGuard` (lid-closed override), `Hook` (hook entry point), `SessionStore`, `ProcessWatcher`, `HookInstaller`, `VigilModel` (state), `Updater` (Sparkle), `VigilApp` + `PanelView` (SwiftUI UI)
