# claudeship

A Claude Code plugin suite for multi-account workflows, usage tracking, safety hooks, macOS notifications, and workspace orchestration.

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

### macOS Notifications (ClaudeNotifier)

A native menubar daemon that shows live session status, subagent progress, and interactive notifications:

- Color-coded account dots in the menubar with a braille spinner for active sessions
- Clickable session panel — click to focus the matching terminal window
- Interactive notifications for permission requests and questions — respond without switching to the terminal
- Subagent progress tracking (`"Agent done (2/5)"`)

### Workspace Orchestration

Manage isolated git worktree + Docker Compose environments per feature branch. Each workspace gets its own branch, worktree directory, and Docker stack routed via Traefik to `*.lvh.me` URLs.

### Statusline

Custom status bar showing account info, git branch, model, and context usage — with spend tracking for API accounts and rate usage for subscription accounts.

## Installation

### 1. Install the plugins

```bash
/plugin marketplace add josh-segal/claudeship
/plugin install claudeship
/plugin install claudeship-workspaces   # optional
```

### 2. Install ClaudeNotifier (optional, macOS only)

```bash
brew tap josh-segal/claudeship https://github.com/josh-segal/claudeship
brew install --cask claude-notifier
```

After install, grant notification permissions:
**System Settings > Notifications > Claude Notifier** — set style to Banners or Alerts.

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
