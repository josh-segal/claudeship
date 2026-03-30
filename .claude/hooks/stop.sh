#!/bin/bash
#
# stop.sh — Stop hook for Claude Code
#
# If Ghostty is focused: ring the terminal bell (tab badge).
# Otherwise: send a macOS notification via the ClaudeNotifier daemon.
#

NOTIFIER="/Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier"
SOCK="/tmp/claude-notifier.sock"

# Kill any existing animation before starting a new one
if [ -f /tmp/claude-anim-pid ]; then
  kill "$(cat /tmp/claude-anim-pid)" 2>/dev/null
  rm -f /tmp/claude-anim-pid
fi

if "$NOTIFIER" check-focus ghostty 2>/dev/null; then
  parent_tty=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
  tty_dev="/dev/$parent_tty"

  if [ -n "$parent_tty" ] && [ "$parent_tty" != "??" ] && [ -w "$tty_dev" ]; then
    printf '\a' > "$tty_dev" 2>/dev/null
  fi
else
  subtitle="$(basename "$PWD")"
  branch=$(git branch --show-current 2>/dev/null)
  [ -n "$branch" ] && subtitle="$subtitle ($branch)"

  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'title':    'Claude Code',
    'message':  'Done',
    'subtitle': sys.argv[1],
    'sound':    'Ping'
}))" "$subtitle" 2>/dev/null)

  [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"
fi

exit 0
