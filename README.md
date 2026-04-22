# claudeship

A Claude Code plugin suite for multi-account workflows, usage tracking, safety hooks, cross-platform notifications, and workspace orchestration.

## Features

### Multi-Account Management

Run multiple Claude Code accounts (work, personal, edu) side by side. Each account gets its own config directory, color-coded indicator, and shell alias. Switch between accounts per-session — no global active account.

### Usage Tracking

Track daily, weekly, and monthly spend and token counts across all accounts. Supports per-account breakdowns and history views via `/usage`.

### Safety Hooks

Lifecycle hooks that protect your environment out of the box:

- **Dangerous command blocking** — prevents `rm -rf /`, `push --force`, `reset --hard`, `curl | sh`, and more
- **File protection** — blocks edits to `.env`, lockfiles, `docker-compose.yml`, and `terraform/`
- **Auto-formatting** — runs Prettier, Ruff, gofmt, or rustfmt on changed files at the end of each turn

### Notifications (ClaudeNotifier)

A notification daemon that shows live session status, subagent progress, and interactive notifications. Ships in two flavors — same socket protocol, same status file, same features — pick the one that matches your OS:

- **macOS** — native Swift menubar app (`notifier/ClaudeNotifier.swift`), installed via Homebrew cask
- **Linux** — Python asyncio daemon (`notifier/daemon/claudeship-notifier.py`) with a Waybar adapter in `notifier/adapters/waybar/`

Both provide:

- Color-coded account indicator with a braille spinner for active sessions
- Clickable session panel — click to focus the matching terminal window
- Interactive notifications for permission requests and questions — respond without switching to the terminal
- Subagent progress tracking (`"Agent done (2/5)"`)

On Linux, interactive dialogs are dispatched through `rofi`, `wofi`, `fuzzel`, or `zenity` (auto-detected, or set via `CLAUDESHIP_DIALOG_TOOL`).

### Workspace Orchestration

Manage isolated git worktrees per feature branch, with configurable lifecycle scripts that run your project's setup, dev-server, and teardown commands.

The workspaces plugin handles the generic parts — creating the worktree, copying `.env` and `.claude/`, generating a workspace-scoped `CLAUDE.md` and `.workspace/` planning artifacts. Project-specific logic (installing deps, starting services, cleaning up) lives in shell scripts your repo owns, wired up through a small `.claudeship.json` config.

```jsonc
// .claudeship.json at your repo root
{
  "workspace": {
    "lifecycle": {
      "setup":    "bash .claudeship/setup.sh",     // runs after worktree is created
      "run":      "bash .claudeship/run.sh",       // starts dev services
      "teardown": "bash .claudeship/teardown.sh"   // runs before worktree is removed
    }
  }
}
```

Scripts receive `$WORKSPACE_PATH`, `$WORKSPACE_NAME`, and `$MAIN_CHECKOUT`. All three hooks are optional — omit what you don't need. `workspace_open` also launches a new Claude Code session in the worktree; on macOS with Ghostty, it opens as a new tab.

#### Starters

Pre-built lifecycle script sets for common project shapes live under `starters/`. Copy one into your repo and edit the marked variables:

| Starter | Directory | What it does |
|---------|-----------|-------------|
| Docker + Traefik | `starters/docker-traefik/` | Shared Traefik reverse proxy, per-workspace Docker Compose routing via `*.lvh.me`, health checks |

```bash
cp -r starters/docker-traefik/.claudeship .claudeship/
cp starters/docker-traefik/.claudeship.json .claudeship.json
# then edit .claudeship/*.sh to match your services and ports
```

Contributions of new starters welcome — each one is a directory with a `.claudeship.json`, a `.claudeship/` script set, and a short `README.md`.

### Statusline

Custom status bar showing account info, git branch, model, and context usage — with spend tracking for API accounts and rate usage for subscription accounts.

## Installation

### 1. Install the plugins

```bash
/plugin marketplace add josh-segal/claudeship
/plugin install claudeship
/plugin install claudeship-workspaces   # optional
```

### 2. Install ClaudeNotifier (optional)

**macOS:**

```bash
brew tap josh-segal/claudeship https://github.com/josh-segal/claudeship
brew install --cask claude-notifier
```

After install, grant notification permissions:
**System Settings > Notifications > Claude Notifier** — set style to Banners or Alerts.

**Linux:**

```bash
bash notifier/install.sh
```

Symlinks the daemon and Waybar adapter into `~/.local/bin` and optionally creates a systemd user service. See `notifier/adapters/waybar/` for module config and CSS snippets.

### 3. Run setup

```
/setup
```

The setup wizard walks you through configuring the statusline, registering accounts, and verifying the notifier connection.

## License

MIT License

Copyright (c) 2026 Joshua Segal

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
