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
import json, sys, os

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

session_id = d.get('session_id', '')
cwd        = d.get('cwd', '')
source     = d.get('source', 'startup')

if not session_id:
    sys.exit(0)

# Detect account from CLAUDE_CONFIG_DIR
account = ''
try:
    config_dir = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')
    config_dir = os.path.realpath(os.path.expanduser(config_dir))
    accounts_path = os.path.expanduser('~/.claude/accounts.json')
    accounts_data = json.load(open(accounts_path))
    for name, info in accounts_data.get('accounts', {}).items():
        registered = os.path.realpath(os.path.expanduser(info.get('config_dir', '')))
        if registered == config_dir:
            account = name
            break
except Exception:
    pass

print(json.dumps({
    'type':       'session_register',
    'session_id': session_id,
    'cwd':        cwd,
    'source':     source,
    'account':    account,
}))
" "$input" 2>/dev/null)

[ -n "$payload" ] && [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"

exit 0
