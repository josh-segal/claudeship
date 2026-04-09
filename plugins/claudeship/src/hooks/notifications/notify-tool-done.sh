#!/bin/bash
#
# notify-tool-done.sh — PostToolUse hook (all tools)
#
# Fires after every tool completes. Sends session_thinking so the status bar
# shows the spinner during the gap between tool uses (thinking tokens).
# If the turn ends after this, turn_stop will correctly overwrite it.
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
print(json.dumps({'type': 'session_thinking', 'session_id': session_id}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && echo "[$(date '+%H:%M:%S.%3N')] session_thinking: $payload" >> "$LOG"
[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
