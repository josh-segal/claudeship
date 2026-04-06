#!/bin/bash
#
# stop.sh — Stop hook for Claude Code
#
# Notifications (sound, bell, panel) are handled by the daemon via
# completeTurnStop, which gates on subagent state. This script only
# handles cleanup tasks that run on every turn stop.
#

# Kill any existing animation before starting a new one
if [ -f /tmp/claude-anim-pid ]; then
  kill "$(cat /tmp/claude-anim-pid)" 2>/dev/null
  rm -f /tmp/claude-anim-pid
fi

python3 "$CLAUDE_PROJECT_DIR/.claude/tools/usage.py" > /dev/null 2>&1 &

exit 0
