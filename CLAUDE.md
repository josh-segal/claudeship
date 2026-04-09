This is a Claude Code plugin monorepo providing multi-account workflows, lifecycle hooks, usage tracking, quality gates, cross-platform notifications, and workspace orchestration.

## Monorepo Layout

```
plugins/
  claudeship/                 — core plugin: accounts, usage, hooks, notifications, statusline
    .claude-plugin/plugin.json
    hooks/, skills/, src/, tests/, pyproject.toml
  claudeship-workspaces/      — workspace orchestration plugin
    .claude-plugin/plugin.json
    .mcp.json, mcp/, workspace.sh
notifier/                     — notification daemons + bar adapters
  ClaudeNotifier.swift          macOS menubar app (distributed via Homebrew cask)
  daemon/                       universal Python daemon (Linux + macOS)
  adapters/waybar/              Waybar custom module adapter + config snippets
Casks/                        — Homebrew cask definition
scripts/                      — bump-version.sh
marketplace.json              — indexes both plugins for /plugin marketplace
```

## Development

### First-time setup

```bash
# Add to ~/.zshrc:
claudeship-dev() {
  eval "$@" --plugin-dir ~/Coding/claudeship/plugins/claudeship \
            --plugin-dir ~/Coding/claudeship/plugins/claudeship-workspaces
}

# Install MCP dependencies
cd plugins/claudeship-workspaces/mcp && npm install && npm run build

# Build notifier (if not installed via Homebrew)
bash notifier/install-notifier.sh
```

### Daily dev

Use `claudeship-dev` to wrap any Claude alias. This loads both plugins live from source:

```bash
claudeship-dev claude-work    # dev plugins + work account
claudeship-dev claude-pers    # dev plugins + personal account
```

Edits to plugin files (hooks, skills, tools) take effect on the next Claude session.

### Auto-rebuild hooks (dev-only, in .claude/settings.json)

- **Swift edits** (`notifier/ClaudeNotifier.swift`): auto-compiles and reloads the daemon
- **TypeScript edits** (`mcp/workspace-server.ts`): auto-recompiles via `npm run build`

### Testing

```bash
cd plugins/claudeship && uv run pytest
cd plugins/claudeship && uv run ruff check
```

## Notification System

The plugin hooks talk to a notification daemon via `/tmp/claude-notifier.sock`. The daemon maintains session state and writes `/tmp/claudeship-status.json` for bar adapters. Two daemon implementations exist:

### macOS (Swift menubar app)

- **Source:** `notifier/ClaudeNotifier.swift`
- **Install:** `brew install --cask claude-notifier`
- **Dev rebuild:** auto via hook on Swift edit, or `bash notifier/rebuild-notifier.sh`
- **Restore published:** `brew reinstall claude-notifier`

### Linux (Python asyncio daemon)

- **Source:** `notifier/daemon/claudeship-notifier.py`
- **Install:** `bash notifier/install.sh` (symlinks to `~/.local/bin`, optional systemd service)
- **Waybar adapter:** `notifier/adapters/waybar/` (config + CSS snippets)
- **Dialog tool:** configurable via `CLAUDESHIP_DIALOG_TOOL` env var (auto-detects rofi/wofi/fuzzel/zenity)

### Logs (both platforms)

`tail -f /tmp/claude-notifier.log`

## Releasing

```bash
# Bump versions in all plugin.json files
scripts/bump-version.sh 0.0.2

# Check for version drift
scripts/bump-version.sh --check

# Commit, tag, push — CI builds notifier + auto-updates cask
git add -A && git commit -m "release v0.0.2"
git tag v0.0.2
git push && git push --tags
```

CI (`release.yml`) builds ClaudeNotifier.app, creates a GitHub Release, and auto-updates `Casks/claude-notifier.rb` with the new SHA256.

Users install plugins via:
```
/plugin marketplace add josh-segal/claudeship
/plugin install claudeship
/plugin install claudeship-workspaces
```
