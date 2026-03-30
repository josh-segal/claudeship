#!/bin/bash
#
# notify-permission.sh — PermissionRequest hook
#
# Fires the instant a tool approval dialog appears.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

input=$(cat)
tool=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_name', 'a tool'))
" 2>/dev/null || echo "a tool")

subtitle="$(basename "$PWD")"
message="Permission needed: $tool"

payload=$(python3 -c "
import json, sys
print(json.dumps({
    'title':    'Claude Code',
    'message':  sys.argv[1],
    'subtitle': sys.argv[2],
    'sound':    'Ping'
}))" "$message" "$subtitle" 2>/dev/null)

echo "[$(date '+%H:%M:%S.%3N')] notify-permission.sh: $message" >> "$LOG"
[ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
