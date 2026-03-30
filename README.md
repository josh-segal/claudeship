# claudeship

## .claude/hooks

Opinionated safety defaults for Claude Code. Configured in `.claude/settings.json`.

**Permissions deny** vs **hooks**: `permissions.deny` glob-matches the tool argument from the start — good for exact patterns like file paths. Hooks receive the full command string and regex-search within it, catching dangerous commands even when chained (e.g. `cd foo && sudo rm -rf /`). Some rules (like `sudo`) appear in both as defense-in-depth.

### Permissions (hard deny)

- No editing/writing dotfiles in `~` (read is allowed)
- No `sudo`

### `block-dangerous-commands.sh`

PreToolUse hook on Bash.

Filesystem:
- `rm -rf /`, `rm -rf *`
- `mkfs`, `dd if=`
- `chmod -R 777 /`
- Write to `/dev/sd*`
- `curl` or `wget` piped to shell

Git:
- `push --force` / `push -f`
- `reset --hard`
- `branch -D`

### `protect-files.sh`

PreToolUse hook on Read, Edit, Write.

- Blocks `.env` and `.env.*` (allows `.env.example`)
- Lockfiles: `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `poetry.lock`, `uv.lock`, `Cargo.lock`
- Infra: `docker-compose*.yml`, `terraform/*`

### `quality-gate.sh`

Stop + SubagentStop hook. Auto-formats changed files using whichever tools are present:

- Prettier (JS/TS)
- Ruff format + check --fix (Python)
- gofmt (Go)
- rustfmt (Rust)

### `stop.sh`

Stop hook. If Ghostty is the focused app, sends a BEL to the terminal (Ghostty adds 🔔 to the tab title). If Ghostty is not focused, sends a macOS notification via the ClaudeNotifier daemon.

### `notifications/`

Hook scripts that send events to the ClaudeNotifier daemon socket. Each maps to a specific Claude Code hook:

| Script | Hook | Trigger |
|---|---|---|
| `notify-session-register.sh` | SessionStart | Session begins — registers it in daemon state |
| `notify-session-start.sh` | UserPromptSubmit | Prompt submitted — marks session as working |
| `notify-session-end.sh` | SessionEnd | Session terminates — removes from daemon state |
| `notify-input.sh` | PreToolUse → AskUserQuestion | Claude asks you a question |
| `notify-input.sh --plan` | PreToolUse → ExitPlanMode | Plan ready for approval |
| `notify-permission.sh` | PermissionRequest | Tool approval dialog appears |
| `notify-elicitation.sh` | Elicitation | MCP server needs input |
| `notify-subagent-start.sh` | SubagentStart | Subagent spawned — registers in daemon state |
| `notify-subagent-stop.sh` | SubagentStop | Subagent finished — posts progress notification |
| `notify-turn-stop.sh` | Stop | Turn ended — marks session idle, clears subagent state |
| `notify-stop-failure.sh` | StopFailure | Turn ended in API error |

#### Interactive notifications

Two hook scripts go beyond passive alerts — they send an actionable notification, poll for the user's tap, then respond programmatically so Claude gets the answer without the terminal being focused.

**`notify-input.sh` (AskUserQuestion)**

When Claude calls `AskUserQuestion` with a single-choice question, the hook:

1. Parses the question text and option labels from the hook JSON.
2. Sends an `input_question` message to the daemon, which posts a native notification with one button per option (up to the macOS limit of ~4).
3. Polls `/tmp/claude-input-reply-<PID>` for up to 10 minutes.
4. When a reply arrives, exits with code 2 and a JSON body containing `updatedInput.answers` — Claude receives the selected answer and continues without terminal interaction.

Falls through to terminal (exit 0) for: `multiSelect` questions, missing options, no daemon socket, or timeout.

**`notify-permission.sh` (PermissionRequest)**

When Claude needs tool approval:

1. Parses the tool name and `permission_suggestions` from the hook JSON to build button labels matching the terminal dialog (e.g. "Yes", "Yes, allow Read from /tmp/**", "No").
2. Sends an `input_question` message and polls for a reply the same way as above.
3. Maps the chosen label back to a `behavior` (`allow`, `allow_suggestion` → `allow`, or `deny`) and exits 2 with `hookSpecificOutput.decision.behavior`.

Falls through to the terminal dialog on timeout.

## ClaudeNotifier

A native macOS notification daemon (`ClaudeNotifier.app`) that powers all notifications and the menu bar status item for this setup.

### Architecture

`ClaudeNotifier` runs as a persistent LaunchAgent (`com.claudeship.notifier`) and listens on a Unix domain socket at `/tmp/claude-notifier.sock`. Hook scripts write JSON to the socket — delivery latency is ~1ms.

All notifications use `.timeSensitive` interruption level to push through Focus modes. Logs write to `/tmp/claude-notifier.log` with 1 MB rotation (previous log kept at `.log.1`).

The daemon manages three subsystems:

**Session registry** — tracks all active Claude sessions. On `session_register` (SessionStart), adds the session keyed by ID with its `cwd` and a display name derived from the directory basename. On `session_working` (UserPromptSubmit), marks the session active. On `turn_stop` (Stop), marks it idle. On `session_end` (SessionEnd), removes it entirely.

**Subagent progress tracking** — maintains in-memory state mapping parent sessions to their spawned subagents. On `subagent_start`, registers the agent name and increments the total count. On `subagent_stop`, increments the completion count and posts `"Agent Name done (2/3)"`. On `turn_stop`, clears state for that session. Gives per-turn progress notifications when Claude spawns multiple parallel agents.

**Interactive reply routing** — for `permission_request` and `input_question` messages, dynamically registers a per-request `UNNotificationCategory` with the appropriate action buttons, posts the notification, and writes the user's choice to `/tmp/claude-input-reply-<requestId>` when a button is tapped. The hook script polls that file and exits with the response.

### Menu bar status item

The daemon runs as a background app (no Dock icon) and shows a persistent status item in the macOS menu bar.

**Title states:**

| State | Title |
|---|---|
| No registered sessions | `✳ claudeship` |
| Sessions present, all idle | `✳ N claudeship` |
| One or more sessions working | `⣾ working/total claudeship` (animated braille spinner) |

The spinner cycles through 8 braille frames at 10 fps while any session is active, then stops when all sessions go idle.

**Dropdown menu:**

Clicking the status item shows a list of all registered sessions sorted alphabetically. Each entry shows:

- `●  name  —  working` or `○  name  —  idle`
- Any active subagents for that session listed as indented items below it

Clicking a session entry runs an AppleScript to focus the matching Ghostty terminal window by `cwd`.

**`check-focus` mode:**

The binary also supports a one-shot query: `ClaudeNotifier check-focus <app-name>` exits 0 if that app is currently frontmost, 1 otherwise. Used by `stop.sh` to decide whether to send a BEL or a notification.

### Setup

```
bash .claude/scripts/install-notifier.sh
```

Then go to **System Settings > Notifications > Claude Notifier** and set the style to **Banners** or **Alerts**.

## workspace.sh

Manages isolated development workspaces using git worktrees and Docker Compose, with Traefik for routing.

Each workspace gets its own worktree, branch, and Docker stack with unique URLs via `*.lvh.me`.

### Commands

```
workspace.sh up <name>       # Create worktree, install deps, start stack
workspace.sh down <name>     # Stop stack (keeps worktree)
workspace.sh destroy <name>  # Stop stack + remove worktree/branch
workspace.sh ls              # List all workspaces
workspace.sh logs <name>     # Tail Docker logs
workspace.sh status <name>   # Show workspace details
```

### How it works

- Creates a git worktree branching from `dev` at `../<project>-worktrees/<name>`
- Branch naming: `<git-user>/<name>`
- Starts a Docker Compose stack with Traefik routing to `cos-<name>.lvh.me` (frontend), `api-cos-<name>.lvh.me` (API), `phoenix-cos-<name>.lvh.me` (Phoenix)
- Copies `.env`, `CLAUDE.md`, and `.claude/` from the main checkout
