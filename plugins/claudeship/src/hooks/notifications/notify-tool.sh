#!/bin/bash
#
# notify-tool.sh — PreToolUse hook for ambient command display
#
# Fires before every Bash/Read/Edit/Write tool call.
# Sends session_tool to daemon so the status bar shows the current operation.
#

SOCK="/tmp/claude-notifier.sock"

input=$(cat)

payload=$(python3 -c "$(cat << 'PYEOF'
import sys, json

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

session_id = d.get('session_id', '')
tool_name  = d.get('tool_name', '')
if not session_id or not tool_name:
    sys.exit(0)

import os, shlex

ti = d.get('tool_input', {})

if tool_name == 'Bash':
    raw = ti.get('command', '')
    try:
        parts = shlex.split(raw)
        # show command + first arg (e.g. "git commit", "ls -la", "npm install")
        preview = ' '.join(parts[:2]) if parts else raw[:30]
    except Exception:
        preview = raw.split()[0] if raw.split() else ''
else:
    raw = ti.get('file_path') or ti.get('path') or ''
    preview = os.path.basename(raw) if raw else ''

print(json.dumps({
    'type':             'session_tool',
    'session_id':       session_id,
    'tool_name':        tool_name,
    'command_preview':  preview
}))
PYEOF
)" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

# Clear any pending permission notifications for this session — a tool firing
# means any pending PermissionRequest was answered (allowed).
clear=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    sid = d.get('session_id', '')
    if sid: print(json.dumps({'type': 'session_inputs_clear', 'session_id': sid}))
except Exception:
    pass
" "$input" 2>/dev/null)
[ -n "$clear" ] && [ -S "$SOCK" ] && printf '%s' "$clear" | nc -U -w 2 "$SOCK"

exit 0
