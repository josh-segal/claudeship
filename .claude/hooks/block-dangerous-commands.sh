#!/bin/bash
#
# block-dangerous-commands.sh — PreToolUse hook for Bash commands
#
# Blocks dangerous shell commands before they execute.
# Exit 2 = block (Claude sees stderr as reason).
# Exit 0 = allow.
#

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
    exit 0
fi

PATTERNS=(
    'rm\s+-rf\s+/'
    'rm\s+-rf\s+\*'
    'mkfs\.'
    'dd\s+if='
    'chmod\s+-R\s+777\s+/'
    '>\s*/dev/sd[a-z]'
    'curl.*\|\s*(ba)?sh'
    'wget.*\|\s*(ba)?sh'
    'git\s+push\s+.*-f'
    'git\s+push\s+.*--force'
    'git\s+reset\s+--hard'
    'git\s+branch\s+-D'
    'sudo\s+'
)

for pattern in "${PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
        echo "BLOCKED: Command matches dangerous pattern '$pattern'." >&2
        exit 2
    fi
done

exit 0
