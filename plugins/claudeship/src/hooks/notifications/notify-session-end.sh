#!/bin/bash
#
# notify-session-end.sh — SessionEnd hook
#
# Fires when a Claude session terminates. Removes the session from
# the daemon's registry so it disappears from the menu bar list.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

if ! read -r -t 5 input && [ -z "$input" ]; then
    echo "[$(date '+%H:%M:%S.%3N')] $(basename "$0"): stdin read timed out" >> "$LOG"
    exit 0
fi

payload=$(python3 -c "
import json, sys

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

session_id = d.get('session_id', '')
if not session_id:
    sys.exit(0)

print(json.dumps({'type': 'session_end', 'session_id': session_id}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && echo "[$(date '+%H:%M:%S.%3N')] session_end: $payload" >> "$LOG"
[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
