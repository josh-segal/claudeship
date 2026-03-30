#!/bin/bash
#
# notify-input.sh — Fires instantly when Claude needs user input.
#
# Handles:
#   PreToolUse → AskUserQuestion  (extracts the question text)
#   PreToolUse → ExitPlanMode     (pass --plan flag)
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

subtitle="$(basename "$PWD")"

if [ "$1" = "--plan" ]; then
  message="Plan ready — awaiting your approval"
else
  input=$(cat)
  message=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
qs = d.get('input', {}).get('questions', [])
print(qs[0]['question'] if qs else 'Claude needs your input')
" 2>/dev/null || echo "Claude needs your input")
fi

payload=$(python3 -c "
import json, sys
print(json.dumps({
    'title':    'Claude Code',
    'message':  sys.argv[1],
    'subtitle': sys.argv[2],
    'sound':    'Ping'
}))" "$message" "$subtitle" 2>/dev/null)

echo "[$(date '+%H:%M:%S.%3N')] notify-input.sh: $message" >> "$LOG"
[ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
