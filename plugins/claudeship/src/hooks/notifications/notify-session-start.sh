#!/bin/bash
#
# notify-session-start.sh — UserPromptSubmit hook
#
# Fires when the user submits a prompt. Tells the daemon to show
# the loading indicator in the menu bar.
#

SOCK="/tmp/claude-notifier.sock"

if ! read -r -t 5 input; then
    echo "[$(date '+%H:%M:%S.%3N')] $(basename "$0"): stdin read timed out" >> /tmp/claude-notifier.log
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

print(json.dumps({'type': 'session_working', 'session_id': session_id}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
