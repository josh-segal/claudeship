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

### `notify.sh`

Notification hook. Sends a macOS notification when Claude needs attention.

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
