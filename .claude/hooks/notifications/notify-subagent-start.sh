#!/bin/bash
#
# notify-subagent-start.sh — SubagentStart hook
#
# Fires when a subagent is spawned. Registers it with the daemon so
# progress can be tracked and shown as "Agent Name done (N/M)".
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"

input=$(cat)

# Log raw JSON so we can verify field names on first run
echo "[$(date '+%H:%M:%S.%3N')] notify-subagent-start.sh RAW: $input" >> "$LOG"

payload=$(python3 -c "
import json, sys

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

# 'session_id' in SubagentStart is the PARENT session; 'agent_id' is the subagent's own ID
parent_session_id = d.get('session_id', '')
agent_id          = d.get('agent_id', '')

# Try common locations for the agent description/name
agent_name = (
    d.get('tool_input', {}).get('description', '') or
    d.get('input', {}).get('description', '')       or
    d.get('agent_type', '')                          or
    ''
)

if not parent_session_id or not agent_id:
    sys.exit(0)

print(json.dumps({
    'type':              'subagent_start',
    'session_id':        agent_id,
    'parent_session_id': parent_session_id,
    'agent_name':        agent_name
}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
