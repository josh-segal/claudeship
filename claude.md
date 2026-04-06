This project is a Claude Code plugin providing multi-account workflows, lifecycle hooks, usage tracking, quality gates, and macOS notifications.

## Plugin Structure

```
.claude-plugin/plugin.json    — manifest
hooks/hooks.json              — hook registrations
skills/                       — /claudeship:usage, /claudeship:setup, etc.
src/tools/                    — Python tools (usage, statusline, accounts, state)
src/hooks/                    — shell hooks (safety, quality-gate, notifications)
src/notifier/                 — ClaudeNotifier macOS app (optional, separate install)
```

## ClaudeNotifier

The daemon runs as a LaunchAgent from `/Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier`.
Source is at `src/notifier/ClaudeNotifier.swift`. Editing the `.swift` file via Claude auto-rebuilds and reloads.

### Manual full reload

```bash
bash src/notifier/rebuild-notifier.sh
```

### Logs

```bash
tail -f /tmp/claude-notifier.log
```

## Development

When working on this repo, the plugin is loaded via `claude --plugin-dir .` from the repo root. The `.claude/settings.json` contains dev-only config (deny rules, auto-rebuild hook).
