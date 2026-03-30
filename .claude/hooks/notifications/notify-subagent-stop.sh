#!/bin/bash
#
# notify-subagent-stop.sh — SubagentStop hook
#
# Fires when a subagent finishes. Sends a lifecycle event to the daemon;
# the daemon handles the notification with correct "Agent Name done (N/M)" text.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

input=$(cat)

# Log raw JSON so we can verify field names on first run
echo "[$(date '+%H:%M:%S.%3N')] notify-subagent-stop.sh RAW: $input" >> "$LOG"

payload=$(python3 -c "
import json, sys

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

session_id        = d.get('session_id', '')
parent_session_id = d.get('parent_session_id', '')

if not session_id or not parent_session_id:
    sys.exit(0)

print(json.dumps({
    'type':              'subagent_stop',
    'session_id':        session_id,
    'parent_session_id': parent_session_id
}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
