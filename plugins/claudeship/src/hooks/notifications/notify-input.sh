#!/bin/bash
#
# notify-input.sh — Fires instantly when Claude needs user input.
#
# Handles:
#   PreToolUse → AskUserQuestion  (shows options as notification buttons)
#   PreToolUse → ExitPlanMode     (pass --plan flag, informational only)
#
# For AskUserQuestion with structured options: sends buttons, polls for reply,
# then responds with exit 2 + JSON so Claude gets the answer without terminal.
# Falls through (exit 0) for multiSelect, missing options, timeout, or no socket.
#

SOCK="/tmp/claude-notifier.sock"
LOG="/tmp/claude-notifier.log"
REQUEST_ID="$$"
REPLY_FILE="/tmp/claude-input-reply-${REQUEST_ID}"

subtitle="$(basename "$PWD")"

# ── Plan mode: informational only ─────────────────────────────────────────────
if [ "$1" = "--plan" ]; then
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'title':    'Claude Code',
    'message':  'Plan ready — awaiting your approval',
    'subtitle': sys.argv[1],
    'sound':    'Ping'
}))" "$subtitle" 2>/dev/null)
    echo "[$(date '+%H:%M:%S.%3N')] notify-input.sh: plan mode" >> "$LOG"
    [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"
    exit 0
fi

# ── AskUserQuestion: parse structured options ─────────────────────────────────
input=$(cat)

parsed=$(echo "$input" | python3 -c "$(cat << 'PYEOF'
import sys, json
d = json.load(sys.stdin)
qs = d.get('input', {}).get('questions', [])
if not qs:
    print("TERMINAL")
    sys.exit(0)
q = qs[0]
question = q.get('question', '')
opts = [o.get('label', '') for o in q.get('options', [])]
if q.get('multiSelect', False) or not opts or not question:
    print("TERMINAL")
    sys.exit(0)
print(json.dumps({'question': question, 'options': opts, 'questions': qs}))
PYEOF
)")

if [ "$parsed" = "TERMINAL" ] || [ -z "$parsed" ]; then
    # multiSelect or no options — let terminal handle it
    message=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
qs = d.get('input', {}).get('questions', [])
print(qs[0]['question'] if qs else 'Claude needs your input')
" 2>/dev/null || echo "Claude needs your input")
    payload=$(python3 -c "
import json, sys
print(json.dumps({
    'title':    'Claude Code',
    'message':  sys.argv[1],
    'subtitle': sys.argv[2],
    'sound':    'Ping'
}))" "$message" "$subtitle" 2>/dev/null)
    echo "[$(date '+%H:%M:%S.%3N')] notify-input.sh: terminal fallback — $message" >> "$LOG"
    [ -S "$SOCK" ] && printf '%s' "$payload" | nc -U -w 2 "$SOCK"
    exit 0
fi

# ── Send actionable notification with option buttons ─────────────────────────
question=$(echo "$parsed" | python3 -c "import json,sys; print(json.load(sys.stdin)['question'])")
options_json=$(echo "$parsed" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['options']))")
questions_json=$(echo "$parsed" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['questions']))")

echo "[$(date '+%H:%M:%S.%3N')] notify-input.sh: $question (id=$REQUEST_ID)" >> "$LOG"

if [ ! -S "$SOCK" ]; then
    exit 0
fi

SESSION_ID="${CLAUDE_SESSION_ID:-}"

payload=$(python3 -c "
import json, sys
print(json.dumps({
    'type':       'input_question',
    'request_id': sys.argv[1],
    'question':   sys.argv[2],
    'options':    json.loads(sys.argv[3]),
    'subtitle':   sys.argv[4],
    'session_id': sys.argv[5]
}))" "$REQUEST_ID" "$question" "$options_json" "$subtitle" "$SESSION_ID" 2>/dev/null)

printf '%s' "$payload" | nc -U -w 2 "$SOCK"

# ── Poll for reply (up to 10 minutes) ────────────────────────────────────────
for i in $(seq 1 600); do
    if [ -f "$REPLY_FILE" ]; then
        chosen=$(cat "$REPLY_FILE")
        rm -f "$REPLY_FILE"
        echo "[$(date '+%H:%M:%S.%3N')] notify-input.sh: reply='$chosen'" >> "$LOG"
        python3 -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'allow',
        'updatedInput': {
            'questions': json.loads(sys.argv[1]),
            'answers':   {sys.argv[2]: sys.argv[3]}
        }
    }
}))" "$questions_json" "$question" "$chosen"
        exit 2
    fi
    sleep 1
done

# ── Timeout — fall through to terminal ───────────────────────────────────────
echo "[$(date '+%H:%M:%S.%3N')] notify-input.sh: timeout, falling through" >> "$LOG"
[ -n "$SESSION_ID" ] && [ -S "$SOCK" ] && \
  printf '%s' "{\"type\":\"session_inputs_clear\",\"session_id\":\"$SESSION_ID\"}" | nc -U -w 1 "$SOCK" 2>/dev/null
exit 0
