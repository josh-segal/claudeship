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
| `notify-input.sh` | PreToolUse → AskUserQuestion | Claude asks you a question |
| `notify-input.sh --plan` | PreToolUse → ExitPlanMode | Plan ready for approval |
| `notify-permission.sh` | PermissionRequest | Tool approval dialog appears |
| `notify-elicitation.sh` | Elicitation | MCP server needs input |
| `notify-subagent-start.sh` | SubagentStart | Subagent spawned — registers in daemon state |
| `notify-subagent-stop.sh` | SubagentStop | Subagent finished — posts progress notification |
| `notify-turn-stop.sh` | Stop | Turn ended — clears subagent tracking state |
| `notify-stop-failure.sh` | StopFailure | Turn ended in API error |

## ClaudeNotifier

A native macOS notification daemon (`ClaudeNotifier.app`) that powers all notifications in this setup.

### Architecture

`ClaudeNotifier` runs as a persistent LaunchAgent (`com.claudeship.notifier`) and listens on a Unix domain socket at `/tmp/claude-notifier.sock`. Hook scripts write JSON to the socket - delivery latency is ~1ms.

The daemon manages two modes:

**Notification delivery** — receives `{"type":"notify","title":"...","message":"...","subtitle":"...","sound":"..."}` and posts a native macOS banner with an "Open Terminal" action button. All notifications use `.timeSensitive` interruption level to push through Focus modes.

**Subagent progress tracking** — maintains in-memory state mapping parent sessions to their spawned subagents. On `subagent_start`, registers the agent name and increments the total count. On `subagent_stop`, increments the completion count and posts `"Agent Name done (2/3)"`. On `turn_stop`, clears state for that session. This gives per-turn progress notifications when Claude spawns multiple parallel agents.

Logs write to `/tmp/claude-notifier.log` with 1MB rotation (previous log kept at `.log.1`).

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
