#!/bin/bash
#
# notify-permission.sh — PermissionRequest hook
#
# Fires when a tool approval dialog appears.
# Sends a notification with Allow / Allow Always / Deny buttons and waits
# for the user's tap, then responds programmatically (exit 2 + JSON).
# Falls through to the terminal dialog on timeout or if the socket is down.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"
REQUEST_ID="$$"
REPLY_FILE="/tmp/claude-input-reply-${REQUEST_ID}"

input=$(cat)
subtitle="$(basename "$PWD")"

parsed=$(echo "$input" | python3 -c "$(cat << 'PYEOF'
import sys, json
d = json.load(sys.stdin)
tool = d.get('tool_name', 'a tool')
tool_input = d.get('tool_input', {})
suggestions = d.get('permission_suggestions', [])

# Build option labels matching what Claude Code shows in the terminal
options = ['Yes']
behaviors = ['allow']

if suggestions:
    s = suggestions[0]
    rules = s.get('rules', [])
    if rules:
        # e.g. "Yes, allow Read from //private/tmp/**"
        rule = rules[0]
        rule_tool = rule.get('toolName', '')
        rule_content = rule.get('ruleContent', '')
        label = f"Yes, allow {rule_tool} from {rule_content}" if rule_tool and rule_content else "Yes, always"
    else:
        label = "Yes, always"
    options.append(label)
    behaviors.append('allow_suggestion')  # marker; echoes suggestions back for persistent rule

options.append('No')
behaviors.append('deny')

print(json.dumps({'tool': tool, 'options': options, 'behaviors': behaviors}))
PYEOF
)")

tool=$(echo "$parsed" | python3 -c "import json,sys; print(json.load(sys.stdin)['tool'])")
options_json=$(echo "$parsed" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['options']))")
behaviors_json=$(echo "$parsed" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['behaviors']))")
suggestions_json=$(echo "$input" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get('permission_suggestions', [])))")

echo "[$(date '+%H:%M:%S.%3N')] notify-permission.sh: $tool (id=$REQUEST_ID)" >> "$LOG"

if [ ! -S "$SOCK" ]; then
    exit 0
fi

SESSION_ID=$(echo "$input" | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

payload=$(python3 -c "
import json, sys
print(json.dumps({
    'type':       'input_question',
    'request_id': sys.argv[1],
    'question':   sys.argv[2],
    'options':    json.loads(sys.argv[3]),
    'subtitle':   sys.argv[4],
    'session_id': sys.argv[5]
}))" "$REQUEST_ID" "$tool" "$options_json" "$subtitle" "$SESSION_ID" 2>/dev/null)

printf '%s' "$payload" | nc -U -w 2 "$SOCK"

# Poll for reply (up to 10 minutes)
# Reply is the chosen option label; map back to behavior via behaviors_json
for i in $(seq 1 600); do
    if [ -f "$REPLY_FILE" ]; then
        chosen=$(cat "$REPLY_FILE")
        rm -f "$REPLY_FILE"
        raw_behavior=$(python3 -c "
import json, sys
options   = json.loads(sys.argv[1])
behaviors = json.loads(sys.argv[2])
chosen    = sys.argv[3]
try:
    idx = options.index(chosen)
    print(behaviors[idx])
except ValueError:
    print('deny')
" "$options_json" "$behaviors_json" "$chosen")
        echo "[$(date '+%H:%M:%S.%3N')] notify-permission.sh: reply='$chosen' → raw_behavior=$raw_behavior" >> "$LOG"
        python3 -c "
import json, sys, os
raw      = sys.argv[1]
sugg     = json.loads(sys.argv[2])
proj_dir = sys.argv[3]
log      = sys.argv[4]

if raw == 'allow_suggestion' and sugg:
    # Build updatedPermissions for Claude Code (may or may not be honored)
    updated_permissions = []
    for s in sugg:
        rules = s.get('rules', [])
        if rules:
            updated_permissions.append({
                'type': 'addRules',
                'rules': rules,
                'behavior': 'allow',
                'destination': s.get('destination', 'localSettings')
            })
    decision = {'behavior': 'allow', 'updatedPermissions': updated_permissions}

    # Also write directly to settings.local.json as a reliable fallback
    local_settings_path = os.path.join(proj_dir, '.claude', 'settings.local.json')
    try:
        if os.path.exists(local_settings_path):
            with open(local_settings_path) as f:
                local = json.load(f)
        else:
            local = {}
        perms = local.setdefault('permissions', {})
        allow_list = perms.setdefault('allow', [])
        for s in sugg:
            for rule in s.get('rules', []):
                tool = rule.get('toolName', '')
                content = rule.get('ruleContent', '')
                entry = f\"{tool}({content})\" if content else tool
                if entry and entry not in allow_list:
                    allow_list.append(entry)
        with open(local_settings_path, 'w') as f:
            json.dump(local, f, indent=2)
        with open(log, 'a') as f:
            f.write(f'[direct-write] settings.local.json updated: {allow_list}\n')
    except Exception as e:
        with open(log, 'a') as f:
            f.write(f'[direct-write] ERROR: {e}\n')
else:
    decision = {'behavior': 'allow' if raw == 'allow' else raw}

print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PermissionRequest',
        'decision': decision
    }
}))
" "$raw_behavior" "$suggestions_json" "$CLAUDE_PROJECT_DIR" "$LOG"
        exit 2
    fi
    sleep 1
done

# Timeout — fall through to terminal dialog
echo "[$(date '+%H:%M:%S.%3N')] notify-permission.sh: timeout, falling through" >> "$LOG"
exit 0
