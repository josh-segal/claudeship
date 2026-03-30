#!/bin/bash
#
# notify-elicitation.sh — Elicitation hook
#
# Fires when an MCP server requests user input during a tool call.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

input=$(cat)
message=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('message', 'MCP server needs your input'))
" 2>/dev/null || echo "MCP server needs your input")

subtitle="$(basename "$PWD")"

payload=$(python3 -c "
import json, sys
print(json.dumps({
    'title':    'Claude Code',
    'message':  sys.argv[1],
    'subtitle': sys.argv[2],
    'sound':    'Ping'
}))" "$message" "$subtitle" 2>/dev/null)

echo "[$(date '+%H:%M:%S.%3N')] notify-elicitation.sh: $message" >> "$LOG"
[ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
