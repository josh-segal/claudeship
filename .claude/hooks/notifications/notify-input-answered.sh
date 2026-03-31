#!/bin/bash
#
# notify-input-answered.sh — PostToolUse hook for AskUserQuestion
#
# Fires immediately after an AskUserQuestion is answered (TUI or status bar).
# Tells the daemon to clear any pending inputs for this session.
#

SOCK="/tmp/claude-notifier.sock"

input=$(cat)

payload=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
session_id = d.get('session_id', '')
if not session_id:
    sys.exit(0)
print(json.dumps({'type': 'session_inputs_clear', 'session_id': session_id}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
