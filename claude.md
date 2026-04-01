This project is an opinionated Claude Code setup for multi-account workflows, lifecycle hooks, MCP server configs, and sandboxed workspaces.

## ClaudeNotifier

The daemon runs as a LaunchAgent from `/Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier`.
Source is at `.claude/tools/ClaudeNotifier.swift`. Editing the `.swift` file via Claude auto-rebuilds and reloads.

### Manual full reload

```bash
cd /Users/joshuasegal/Coding/claudeship
swiftc .claude/tools/ClaudeNotifier.swift -o .claude/tools/ClaudeNotifier -framework Cocoa
cp .claude/tools/ClaudeNotifier /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
codesign --force --sign - /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
launchctl unload ~/Library/LaunchAgents/com.claudeship.notifier.plist
launchctl load ~/Library/LaunchAgents/com.claudeship.notifier.plist
```

### Logs

```bash
tail -f /tmp/claude-notifier.log
```

## Commands

### /usage
Run `python3 $CLAUDE_PROJECT_DIR/.claude/tools/usage.py` and report the output. Shows daily, weekly,
and monthly Claude Code spend and token counts.
