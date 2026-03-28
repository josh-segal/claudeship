#!/bin/bash
#
# notify.sh — Notification hook for Claude Code
#
# Sends a macOS notification when Claude needs attention.
#

/Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier "Claude Code" "Claude needs your attention" "Ping" &

exit 0
