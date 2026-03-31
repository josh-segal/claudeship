#!/bin/bash
#
# notify-session-stop.sh — Stop hook (session cleanup)
#
# Fires when the parent session ends. Tells the daemon to clear
# subagent tracking state for this session.
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

print(json.dumps({'type': 'turn_stop', 'session_id': session_id}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

# Clear any pending input/permission notifications — turn ending means any
# pending question was answered (or denied) in the TUI.
clear=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    sid = d.get('session_id', '')
    if sid: print(json.dumps({'type': 'session_inputs_clear', 'session_id': sid}))
except Exception:
    pass
" "$input" 2>/dev/null)
[ -n "$clear" ] && [ -S "$SOCK" ] && printf '%s' "$clear" | nc -U -w 2 "$SOCK"

exit 0
