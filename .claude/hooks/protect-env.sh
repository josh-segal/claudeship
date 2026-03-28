#!/bin/bash
#
# protect-env.sh — PreToolUse hook for Read, Edit, Write
#
# Blocks access to .env files except .env.example.
# Exit 2 = block. Exit 0 = allow.
#

INPUT=$(cat)

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -z "$FILE" ]; then
    exit 0
fi

BASENAME=$(basename "$FILE")

case "$BASENAME" in
    .env|.env.*)
        if [ "$BASENAME" = ".env.example" ]; then
            exit 0
        fi
        echo "BLOCKED: Cannot access $BASENAME — it may contain secrets." >&2
        echo "Use .env.example as a reference instead." >&2
        exit 2
        ;;
esac

exit 0
