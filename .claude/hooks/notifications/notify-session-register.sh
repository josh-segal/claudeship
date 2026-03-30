#!/bin/bash
#
# notify-session-register.sh — SessionStart hook
#
# Fires when a Claude session begins or resumes. Registers the session
# with the daemon so it appears in the menu bar session list.
#

SOCK="/tmp/claude-notifier.sock"

input=$(cat)

payload=$(python3 -c "
import json, sys

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

session_id = d.get('session_id', '')
cwd        = d.get('cwd', '')
source     = d.get('source', 'startup')

if not session_id:
    sys.exit(0)

print(json.dumps({
    'type':       'session_register',
    'session_id': session_id,
    'cwd':        cwd,
    'source':     source,
}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
