---
name: setup
description: Configure claudeship after installation. Sets up statusline, accounts, and optional notifier.
user-invocable: true
allowed-tools: Bash
---

# Claudeship Setup

Help the user configure claudeship. Walk through each section in order.

## ClaudeNotifier (optional)

Detect the user's OS first:
```
!uname -s
```

### macOS

Install the ClaudeNotifier menubar app via Homebrew:

```bash
brew install --cask claude-notifier
```

After install:
1. The app is unsigned, so macOS will block it on first launch. Go to **System Settings > Privacy & Security**, scroll to the Security section, and click **"Open Anyway"** next to the ClaudeNotifier warning.
2. Grant notification permissions: **System Settings > Notifications > Claude Notifier** and set the style to Banners or Alerts.

### Linux

Run the Linux installer to set up the notification daemon and Waybar adapter:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/../../notifier/install.sh
```

This installs `claudeship-notifier` (daemon) and `claudeship-waybar-adapter` to `~/.local/bin`, and optionally creates a systemd user service. Follow the printed instructions to add the Waybar config snippet.

Without the notifier, all hooks still work — notification features just silently skip.

## StatusLine

The statusline shows account info, git branch, model, context usage, and spend in the Claude Code status bar. Plugins cannot auto-configure this, so the user needs to add it manually.

Run this to get the resolved path:
```
!echo ${CLAUDE_PLUGIN_ROOT}/src/tools/statusline.py
```

Tell the user to add this to their `~/.claude/settings.json` (or their account's settings.json):

```json
"statusLine": {
  "type": "command",
  "command": "python3 <RESOLVED_PATH>"
}
```

Replace `<RESOLVED_PATH>` with the actual path printed above.

## Accounts (optional)

If the user wants to set up multi-account support, run the interactive wizard:
```
!python3 ${CLAUDE_PLUGIN_ROOT}/src/tools/accounts.py setup
```
