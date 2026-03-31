#!/bin/bash
#
# notify-post-tool-failure.sh — PostToolUseFailure hook
#
# Fires when a tool fails. If the failure was caused by a user interrupt
# (is_interrupt: true), clear any pending inputs and idle the session.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

input=$(cat)

# Only act on user interrupts
is_interrupt=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('1' if d.get('is_interrupt') else '0')
" 2>/dev/null || echo "0")

[ "$is_interrupt" != "1" ] && exit 0

session_id=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('session_id', ''))
" 2>/dev/null || echo "")

[ -z "$session_id" ] && exit 0
[ ! -S "$SOCK" ] && exit 0

tool=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_name', ''))
" 2>/dev/null || echo "")

echo "[$(date '+%H:%M:%S.%3N')] notify-post-tool-failure.sh: interrupt tool=$tool session=$session_id" >> "$LOG"

# Clear pending inputs — handles AskUserQuestion being interrupted
clear=$(python3 -c "import json,sys; print(json.dumps({'type':'session_inputs_clear','session_id':sys.argv[1]}))" "$session_id" 2>/dev/null)
[ -n "$clear" ] && printf '%s' "$clear" | nc -U -w 2 "$SOCK"

# Idle the session — stops spinner without marking done
idle=$(python3 -c "import json,sys; print(json.dumps({'type':'session_idle','session_id':sys.argv[1]}))" "$session_id" 2>/dev/null)
[ -n "$idle" ] && printf '%s' "$idle" | nc -U -w 2 "$SOCK"

exit 0
