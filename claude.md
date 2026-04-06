This project is an opinionated Claude Code setup for multi-account workflows, lifecycle hooks, MCP server configs, and sandboxed workspaces.

## ClaudeNotifier

The daemon runs as a LaunchAgent from `/Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier`.
Source is at `~/.claude/tools/ClaudeNotifier.swift`. Editing the `.swift` file via Claude auto-rebuilds and reloads.

### Manual full reload

```bash
cd ~/.claude
swiftc tools/ClaudeNotifier.swift -o tools/ClaudeNotifier -framework Cocoa
cp tools/ClaudeNotifier /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
codesign --force --sign - /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
launchctl unload ~/Library/LaunchAgents/com.claudeship.notifier.plist
launchctl load ~/Library/LaunchAgents/com.claudeship.notifier.plist
```

### Logs

```bash
tail -f /tmp/claude-notifier.log
```

## Tools and Hooks

All hooks and tools live at the user level in `~/.claude/`:
- `~/.claude/tools/` — ClaudeNotifier, usage.py, statusline.py, accounts.py, state.py
- `~/.claude/hooks/` — lifecycle hooks and notification scripts
- `~/.claude/settings.json` — hook configuration (user-level, applies to all projects)

## Commands

### /usage
Run `python3 $HOME/.claude/tools/usage.py` and report the output. Shows daily, weekly,
and monthly Claude Code spend and token counts.
