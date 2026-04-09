#!/bin/bash
#
# stop.sh — Stop hook for Claude Code
#
# Rings the terminal bell (Ghostty tab indicator) and handles cleanup.
# Sound and panel notifications are handled by the daemon via
# completeTurnStop, which gates on subagent state.
#

# Kill any existing animation before starting a new one
if [ -f /tmp/claude-anim-pid ]; then
  kill "$(cat /tmp/claude-anim-pid)" 2>/dev/null
  rm -f /tmp/claude-anim-pid
fi

# Ring terminal bell so Ghostty shows the tab indicator.
# Write directly to the TTY device — stdout is captured by Claude Code.
parent_tty=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
if [ -n "$parent_tty" ] && [ "$parent_tty" != "??" ]; then
  tty_dev="/dev/$parent_tty"
  [ -w "$tty_dev" ] && printf '\a' > "$tty_dev" 2>/dev/null
fi

# Update usage stats in background (don't block turn completion)
python3 "${CLAUDE_PLUGIN_ROOT}/src/tools/usage.py" > /dev/null 2>&1 &

exit 0
