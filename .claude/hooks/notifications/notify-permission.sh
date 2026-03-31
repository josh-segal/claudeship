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
    behaviors.append('allow_suggestion')  # marker; mapped to allow for now

options.append('No')
behaviors.append('deny')

print(json.dumps({'tool': tool, 'options': options, 'behaviors': behaviors}))
PYEOF
)")

tool=$(echo "$parsed" | python3 -c "import json,sys; print(json.load(sys.stdin)['tool'])")
options_json=$(echo "$parsed" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['options']))")
behaviors_json=$(echo "$parsed" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['behaviors']))")

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
        behavior=$(python3 -c "
import json, sys
options   = json.loads(sys.argv[1])
behaviors = json.loads(sys.argv[2])
chosen    = sys.argv[3]
try:
    idx = options.index(chosen)
    b = behaviors[idx]
    # allow_suggestion falls back to allow until we have the rules response format
    print('allow' if b == 'allow_suggestion' else b)
except ValueError:
    print('deny')
" "$options_json" "$behaviors_json" "$chosen")
        echo "[$(date '+%H:%M:%S.%3N')] notify-permission.sh: reply='$chosen' → behavior=$behavior" >> "$LOG"
        python3 -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PermissionRequest',
        'decision': {
            'behavior': sys.argv[1]
        }
    }
}))" "$behavior"
        exit 2
    fi
    sleep 1
done

# Timeout — fall through to terminal dialog
echo "[$(date '+%H:%M:%S.%3N')] notify-permission.sh: timeout, falling through" >> "$LOG"
exit 0
