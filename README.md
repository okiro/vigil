<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Vigil icon">
</p>

<h1 align="center">Vigil</h1>

<p align="center">
  <b>Your Mac stays awake while your AI agent works, and sleeps as soon as it's done.</b>
</p>

<p align="center">
  <a href="https://github.com/okiro/vigil/releases/latest/download/Vigil.dmg">
    <img src="https://img.shields.io/badge/Download_for_macOS-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" height="44">
  </a>
  <br>
  <sub>Free · macOS 13 Ventura or later · Apple silicon and Intel</sub>
</p>

<p align="center">
  <img src="docs/screenshot.png" width="366" alt="Vigil's menu-bar panel keeping the Mac awake while Claude Code works">
</p>

---

You give Claude Code a big task and go make a coffee. When you come back, your Mac fell asleep ten minutes in and the job is half done. Or you keep the Mac awake "just in case", and it runs all night even though the agent finished at 1 a.m.

Vigil sits in your menu bar and handles both. It keeps your Mac awake exactly as long as an agent is working. Then it lets your Mac sleep normally again.

## Features

- **Knows when Claude is actually working.** Connect Claude Code with one click. Vigil keeps the Mac awake from the moment you send a prompt until Claude finishes replying, not just while Claude Code is open.
- **Works with other agents too.** Codex, Aider and Ollama are watched out of the box. You can add any other tool by name.
- **Your screen still locks.** Vigil keeps the Mac running but lets the display turn off and lock as usual. If you want the screen to stay on, turn on **Keep display on**.
- **Timer.** Need the Mac awake for a download or a long build? Pick anything from 30 minutes to 8 hours. When time's up, Vigil goes back to normal.
- **Status at a glance.** The cup in your menu bar fills in while the Mac is kept awake. It also shows how many agents are working and how much time is left on a timer.
- **Updates itself.** New versions install quietly in the background, never in the middle of an agent's run.
- **Never touches your settings.** Vigil doesn't change your Mac's power settings. If it quits or crashes, your Mac goes straight back to sleeping normally.

## Modes

| Mode | What it does |
|---|---|
| **Auto** | Awake only while an agent is working. This is the default. |
| **Always** | Awake until you switch it off. |
| **Off** | Your Mac sleeps as usual. |
| **Timer** | Awake for 30 min to 8 h, then switches back. |

## Get started

1. **[Download Vigil](https://github.com/okiro/vigil/releases/latest/download/Vigil.dmg)**, open the `.dmg` and drag Vigil into **Applications**.
2. Open Vigil. A cup appears in your menu bar.
3. Click the cup and press **Connect** to link Claude Code. If you already have Claude Code open, restart it so it picks up the change.

That's it. Turn on **Launch at login** in the panel if you want Vigil to start every time you log in.

## Questions

<details>
<summary><b>Will my Mac stay awake with the lid closed?</b></summary>
<br>
No. Closing the lid puts a Mac to sleep unless it's plugged in and connected to an external display. Apps can only get around this by turning off sleep for the whole system, and Vigil deliberately doesn't.
</details>

<details>
<summary><b>Which AI tools does it work with?</b></summary>
<br>
Claude Code works best: once connected, Vigil knows exactly when each reply starts and ends. Codex, Aider and Ollama keep the Mac awake while they're running. To watch another tool, type its name under <b>Watch other agents</b> in the panel.
</details>

<details>
<summary><b>What does "Connect" change?</b></summary>
<br>
It adds a few small hooks to Claude Code's settings file (<code>~/.claude/settings.json</code>) so Claude tells Vigil when it starts and stops working. Vigil saves a backup of the file before every change. You can disconnect any time from the ⋯ menu in the panel.
</details>

<details>
<summary><b>An agent finished but Vigil still shows it as working.</b></summary>
<br>
Hover over it in the panel and click ✕ to release it. Vigil also clears it automatically once Claude Code closes, or after 6 hours.
</details>

<details>
<summary><b>Does Vigil collect any data?</b></summary>
<br>
No. The only connection it makes is to GitHub, once a day, to check for updates.
</details>

<details>
<summary><b>How do I uninstall it?</b></summary>
<br>
Open the panel, choose <b>Disconnect Claude Code</b> from the ⋯ menu, then <b>Quit</b>. Drag Vigil from Applications to the Trash.
</details>

---

<sub>Want to build Vigil yourself or see how it works? Head to <a href="DEVELOPMENT.md">DEVELOPMENT.md</a>.</sub>
