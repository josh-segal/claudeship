# claudeship

An opinionated Claude Code setup built around one principle: every tool is a thin, independently useful script that reads and writes a shared state contract. No monolithic hubs. Add a feature, wire it in, done.

## Design Philosophy

**Shared state, not shared code.** All tools read/write `~/.claude/state.json` via `state.py`. No tool calls another directly — they compose through state.

**Two display channels.** The ClaudeNotifier daemon handles everything visual:
- **Unix socket** (`/tmp/claude-notifier.sock`) — transient session events (working, idle, tool use, subagents)
- **`~/.claude/state.json`** — persistent state (accounts, usage, workspace) read by the daemon via FSEvents

**Hooks stay lean.** Lifecycle hooks are bash scripts that do one thing: send a JSON message to the socket. Heavy logic lives in Python tools. Swift handles display.

**Extend, don't fork.** Adding a new module means: write a script that reads/writes state.json, optionally add a socket message type to ClaudeNotifier, optionally add a CLAUDE.md command. Existing modules don't change.

---

## Tools

### `~/.claude/tools/state.py`

Shared atomic JSON R/W utility used by all claudeship scripts. Provides `read_state()` and `write_state(updates)` with `fcntl` file locking and atomic temp-file-rename writes. Never hand-roll `~/.claude/state.json` operations.

### `~/.claude/tools/usage.py`

Reads all `~/.claude/projects/**/*.jsonl`, sums `costUSD` and token counts grouped by day, week, and month, and writes results to `~/.claude/state.json`.

```bash
python3 ~/.claude/tools/usage.py          # human-readable table
python3 ~/.claude/tools/usage.py --json   # machine-readable JSON
```

Or ask Claude directly: `/usage`

### `~/.claude/tools/accounts.py`

Manages the account registry at `~/.claude/accounts.json`. Shell aliases are the switching mechanism — no global active account concept.

```bash
python3 ~/.claude/tools/accounts.py list
python3 ~/.claude/tools/accounts.py add work --config-dir ~/.claude-work --color green
python3 ~/.claude/tools/accounts.py remove work
python3 ~/.claude/tools/accounts.py current
```

Each account has a `config_dir` (maps to `CLAUDE_CONFIG_DIR`) and a `color`. Launch aliases are the switch:

```bash
alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
alias claude-edu='CLAUDE_CONFIG_DIR=~/.claude-edu claude'
```

Account is detected at session start from `CLAUDE_CONFIG_DIR` and tracked per-session — different sessions can run under different accounts simultaneously.

---

## ClaudeNotifier

A native macOS daemon (`ClaudeNotifier.app`) that powers the menu bar status item and all notifications.

### Architecture

Runs as a persistent LaunchAgent (`com.claudeship.notifier`), listening on `/tmp/claude-notifier.sock`. Hook scripts write JSON to the socket (~1ms delivery). Logs to `/tmp/claude-notifier.log` with 1 MB rotation.

**Session registry** — tracks active Claude sessions keyed by session ID. Registers on SessionStart, marks working on UserPromptSubmit, marks idle on Stop, removes on SessionEnd.

**Subagent tracking** — maps parent sessions to spawned agents. Posts `"Agent done (N/M)"` progress notifications. Clears on turn end.

**Interactive reply routing** — for `AskUserQuestion` and `PermissionRequest`, posts native notifications with action buttons and writes the user's choice back to a temp file or FIFO that the hook script polls.

**Account display** — reads `~/.claude/accounts.json` on startup and on `accounts_changed` socket message. Renders per-session colored `●` dots in the panel and statusline using `NSAttributedString`.

### Menu Bar

| State | Title |
|---|---|
| No sessions | `✳ claudeship` |
| Sessions idle | `✳ N claudeship` |
| Session working, no account | `⣾ working/total claudeship` |
| Session working, with account | `⣾ ●● working/total claudeship` (colored dots per account) |

Spinner cycles 8 braille frames at 10 fps. Dots in statusline reflect working sessions only — idle sessions show their account in the panel, not the bar.

**Panel** (click status item or Cmd+Shift+C):

```
⣾  claudeship ●  —  Bash: npm test       ← work session (green dot)
○  side-project ●  —  idle               ← personal session (blue dot)
↳  test-runner                            ← subagent
```

Clicking a session focuses the matching Ghostty window via AppleScript.

**`check-focus` mode:** `ClaudeNotifier check-focus <app>` exits 0 if that app is frontmost. Used by `stop.sh` to decide BEL vs notification.

### Setup

```bash
bash .claude/scripts/install-notifier.sh
```

Then **System Settings → Notifications → Claude Notifier** → set style to Banners or Alerts.

### Rebuilding

Editing `ClaudeNotifier.swift` via Claude auto-rebuilds and reloads (PostToolUse hook). Manual:

```bash
swiftc .claude/tools/ClaudeNotifier.swift -o .claude/tools/ClaudeNotifier -framework Cocoa
cp .claude/tools/ClaudeNotifier /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
codesign --force --sign - /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
launchctl unload ~/Library/LaunchAgents/com.claudeship.notifier.plist
launchctl load ~/Library/LaunchAgents/com.claudeship.notifier.plist
```

Logs: `tail -f /tmp/claude-notifier.log`

---

## Hooks

Configured in `.claude/settings.json`. All hooks are lean bash — they read input, send a socket message or check a condition, exit.

### Safety

**`block-dangerous-commands.sh`** — PreToolUse on Bash. Blocks: `rm -rf /`, `rm -rf *`, `mkfs`, `dd if=`, `chmod -R 777 /`, writes to `/dev/sd*`, `curl|sh`, `wget|sh`, `push --force`, `reset --hard`, `branch -D`.

**`protect-files.sh`** — PreToolUse on Read/Edit/Write. Blocks: `.env*` (except `.env.example`), lockfiles (`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `poetry.lock`, `uv.lock`, `Cargo.lock`), `docker-compose*.yml`, `terraform/*`.

**`quality-gate.sh`** — Stop + SubagentStop. Auto-formats changed files: Prettier (JS/TS), Ruff (Python), gofmt (Go), rustfmt (Rust).

**`stop.sh`** — Stop hook. BEL to terminal if Ghostty is focused; macOS notification via daemon if not.

**Permissions (hard deny):** no writing dotfiles in `~`, no `sudo`.

### Notification Hooks (`notifications/`)

| Script | Hook | Purpose |
|---|---|---|
| `notify-session-register.sh` | SessionStart | Register session + detect account |
| `notify-session-start.sh` | UserPromptSubmit | Mark session working |
| `notify-session-end.sh` | SessionEnd | Remove session |
| `notify-input.sh` | PreToolUse → AskUserQuestion | Interactive question via notification |
| `notify-input.sh --plan` | PreToolUse → ExitPlanMode | Plan approval via notification |
| `notify-permission.sh` | PermissionRequest | Tool approval via notification |
| `notify-elicitation.sh` | Elicitation | MCP input via notification |
| `notify-subagent-start.sh` | SubagentStart | Register subagent |
| `notify-subagent-stop.sh` | SubagentStop | Post progress notification |
| `notify-turn-stop.sh` | Stop | Mark session idle |
| `notify-stop-failure.sh` | StopFailure | Signal API error |

**Interactive notifications:** `notify-input.sh` and `notify-permission.sh` post native notifications with action buttons, poll for the user's tap, and exit with the chosen answer — Claude gets the response without the terminal needing focus. Falls through to terminal on timeout.

---

## Workspaces

`workspace.sh` manages isolated git worktree + Docker Compose environments. Each workspace gets its own branch, worktree, and Docker stack routed via Traefik to `*.lvh.me` URLs.

```bash
workspace.sh up <name>       # Create worktree, install deps, start stack
workspace.sh down <name>     # Stop stack (keeps worktree)
workspace.sh destroy <name>  # Stop stack + remove worktree and branch
workspace.sh ls              # List all workspaces
workspace.sh logs <name>     # Tail Docker logs
workspace.sh status <name>   # Show workspace details
```

The workspace MCP server (`mcp/workspace-server.ts`) exposes these as Claude tools: `workspace_suggest`, `workspace_create`, `workspace_open`, `workspace_list`, `workspace_status`, `workspace_destroy`.

---

## State Contract

`~/.claude/state.json` — runtime state shared across all tools:

```json
{
  "active_workspace": null,
  "usage": {
    "daily":   { "cost": 0.0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0 },
    "weekly":  { "cost": 0.0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0 },
    "monthly": { "cost": 0.0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0 },
    "updated_at": null
  }
}
```

`~/.claude/accounts.json` — static account registry (edit manually or via `accounts.py`):

```json
{
  "accounts": {
    "personal": { "display_name": "Personal", "config_dir": "~/.claude",      "color": "blue"   },
    "work":     { "display_name": "Work",     "config_dir": "~/.claude-work", "color": "green"  }
  }
}
```

---

## License

MIT License

The MIT License (MIT)

Copyright (c) 2026 Joshua Segal

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
