#!/bin/bash
#
# stop.sh — Stop hook for Claude Code
#
# If Ghostty is not focused: send a macOS notification.
# If Ghostty is focused: ring the bell (🔔 in tab title, clears on focus).
#

# Kill any existing animation before starting a new one
if [ -f /tmp/claude-anim-pid ]; then
  kill "$(cat /tmp/claude-anim-pid)" 2>/dev/null
  rm -f /tmp/claude-anim-pid
fi

focused=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)

if [ "$focused" = "ghostty" ]; then
  parent_tty=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
  tty_dev="/dev/$parent_tty"

  if [ -n "$parent_tty" ] && [ "$parent_tty" != "??" ] && [ -w "$tty_dev" ]; then
    printf '\a' > "$tty_dev" 2>/dev/null
  fi
else
  # Ghostty is not focused — send a macOS notification
  osascript -e 'display notification "Claude Code is done" with title "Claude Code" sound name "Ping"' 2>/dev/null
fi

exit 0
