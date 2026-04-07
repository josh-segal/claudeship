---
name: setup
description: Configure claudeship after installation. Sets up statusline, accounts, and optional notifier.
user-invocable: true
allowed-tools: Bash, Read, Edit
---

# Claudeship Setup

Help the user configure claudeship. Walk through each section in order.

## ClaudeNotifier (optional, macOS only)

For macOS desktop notifications (permission prompts, session tracking, menu bar status), the user can install the ClaudeNotifier app via Homebrew:

```bash
brew install --cask claude-notifier
```

After install:
1. The app is unsigned, so macOS will block it on first launch. Go to **System Settings > Privacy & Security**, scroll to the Security section, and click **"Open Anyway"** next to the ClaudeNotifier warning.
2. Grant notification permissions: **System Settings > Notifications > Claude Notifier** and set the style to Banners or Alerts.

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

## Config Permissions

Claudeship needs permission to edit files in `~/.claude/` (and `~/.claude-*/` for multi-account setups) so that backup/restore and account management work correctly.

Read the user's `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json` if set). Check if the `permissions.allow` array already contains entries for `Edit(~/.claude/**)` and `Write(~/.claude/**)`.

If not, add these allow rules to the `permissions.allow` array (create the array if it doesn't exist):

```json
"Edit(~/.claude/**)",
"Edit(~/.claude-*/**)",
"Write(~/.claude/**)",
"Write(~/.claude-*/**)"
```

Tell the user what you're adding and why before making the edit. If the user declines, note that backup/restore will still work (it uses git commands internally) but Claude won't be able to directly edit config files.

## Accounts (optional)

If the user wants to set up multi-account support, run the interactive wizard:
```
!python3 ${CLAUDE_PLUGIN_ROOT}/src/tools/accounts.py setup
```
