# blink

A tiny dot in your Mac's menu bar that tells you when Claude Code sessions are
done, and takes you to them.

- `○` nothing waiting · `● 2` two sessions done · `◐` a session needs you
- When a session finishes or needs you (a permission prompt or a question), a
  small card drops down under the dot for a few seconds. It's silent, and it
  doesn't steal focus.
- Hover the dot to see every session: `2 done · 3 running · 1 needs you`.
- Click a session to jump to it: the exact VS Code terminal tab or Claude
  panel tab, or the exact Terminal.app tab. Done sessions then leave the list.
  `✕` clears one without jumping; **Clear done** clears them all.
- Left-click pins the list open (click anywhere else to close it).
  Right-click: Clear done · Pause popups · Launch at login · Quit. While
  popups are paused, the dot is dimmed.
- Respects Reduce Motion, and follows light and dark mode.

It's a ~440 KB native app (one Swift file, AppKit). It uses no CPU while idle:
nothing polls. Claude Code hooks write a small file per session, and the app
wakes only when a file changes or a session's process exits.

## Install

Requires macOS 13+, the Xcode Command Line Tools (`xcode-select --install`),
`jq` (bundled with macOS 15+), and Claude Code.

```sh
git clone https://github.com/yashpincha/blink ~/blink
~/blink/install.sh
```

The installer:

1. Creates a local code-signing certificate named `blink` in your login
   keychain, so macOS permissions survive rebuilds. The first build may ask
   you to let `codesign` use it; choose **Always Allow**.
2. Builds the app into `~/Applications/blink.app`.
3. Adds the hooks to `~/.claude/settings.json`. It saves a backup first,
   keeps your existing hooks, and is safe to re-run.
4. Installs the VS Code helper extension if the `code` command is available.
5. Starts the app and turns on launch at login.

Then:

- Open Claude Code sessions pick up the hooks on their next prompt. If one
  never shows up, restart it.
- **Find the dot.** On a MacBook with a notch, macOS hides menu bar icons that
  don't fit. Hold ⌘ and drag the dot next to the clock; macOS remembers
  where you put it.
- **Grant Accessibility (optional).** It lets blink see which VS Code
  window is in front, so it skips the card for a session you're already
  looking at. Without it, everything else still works.
- On your first click on a VS Code session, VS Code asks to let blink
  open a link; tick "Don't ask again". On your first Terminal.app click,
  allow blink to control Terminal.

To update, run `git pull && ./install.sh`. To remove everything, run
`./uninstall.sh` (`--keep-cert` keeps the signing certificate).

## How it works

```
Claude Code ──hooks──▶ ~/.claude/blink/sessions/<id>.state ──watched by──▶ blink.app
```

| Hook | Writes |
| --- | --- |
| `UserPromptSubmit` | `running` |
| `Stop`, `StopFailure` | `done`, with Claude's last message |
| `Notification` (`permission_prompt`, `elicitation_*`, `agent_needs_input`), `PreToolUse` `AskUserQuestion` | `needs` |
| `PostToolUse` | `running` again after `needs`, `done` or `idle`: Claude or a subagent is using tools, even with no typed prompt (a subagent reported back) |
| `Notification` `idle_prompt` | `idle`, which clears a stale state after you interrupt Claude |
| `PostToolUseFailure` | `idle` when you interrupt Claude mid-tool (Esc), since no `Stop` follows |
| `SessionEnd` | deletes the file |

The hooks run `async`, so Claude never waits on them. The hook is a short
POSIX `sh` script: on most tool calls it reads one line with shell builtins
and exits. Only interactive sessions count. `claude -p` and SDK runs are
ignored.

Jumping to a session:

- **VS Code terminal:** the session's IDE port leads to the extension host
  listening on it, and VS Code's logs map that to a `windowId`. blink then
  opens `vscode://yashpincha.blink/focus?pid=…&windowId=…`. VS Code raises
  that window, and the companion extension (`vscode/`, about 20 lines, loaded
  only by that link) shows the terminal whose shell is the session's parent.
- **VS Code Claude panel:** the same lookup, using Claude's parent process.
  It opens `vscode://anthropic.claude-code/open?session=…&windowId=…`.
- **Terminal.app:** AppleScript selects the tab whose tty matches the
  session's. The script is compiled once and sends one-way messages (it never
  waits on Terminal), and blink nudges Terminal awake when you open the
  panel. Terminal is in front ~15–50 ms after the click.

## Privacy

Everything stays on your Mac. blink makes no network calls and keeps no
logs. The panel is excluded from screen sharing and recordings (where macOS
honors that). Session files hold the first line of Claude's last message and
your prompts, and they're deleted when the session ends.

## Develop

```sh
./build.sh          # build/blink.app
./build.sh test     # unit tests (tests/main.swift) and hook tests (tests/hook_test.sh)
./build.sh vsix     # build/blink.vsix
```

## License

MIT
