#!/bin/bash
#
# notify-stop-failure.sh — StopFailure hook
#
# Fires when a turn ends due to an API error.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

input=$(cat)
error=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('error', 'Unknown error'))
" 2>/dev/null || echo "Unknown error")

subtitle="$(basename "$PWD")"
message="Error: $error"

payload=$(python3 -c "
import json, sys
print(json.dumps({
    'title':    'Claude Code',
    'message':  sys.argv[1],
    'subtitle': sys.argv[2],
    'sound':    'Basso'
}))" "$message" "$subtitle" 2>/dev/null)

echo "[$(date '+%H:%M:%S.%3N')] notify-stop-failure.sh: $message" >> "$LOG"
[ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
