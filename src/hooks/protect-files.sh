#!/bin/bash
#
# protect-files.sh — PreToolUse hook for Edit, Write, Read
#
# Blocks access to protected files. Ships with broad defaults
# that work whether or not the project uses a given tool.
#
# Exit 2 = block. Exit 0 = allow.
#

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
    exit 0
fi

BASENAME=$(basename "$FILE_PATH")

# ─── Allowlist (checked first) ───────────────────────────────────────
ALLOWED_BASENAMES=(
    ".env.example"
)

for allowed in "${ALLOWED_BASENAMES[@]}"; do
    if [[ "$BASENAME" == "$allowed" ]]; then
        exit 0
    fi
done

# ─── Protected basename patterns ────────────────────────────────────
BASENAME_PATTERNS=(
    ".env*"                  # environment files (secrets)
    "package-lock.json"      # lockfiles — generated, not hand-edited
    "pnpm-lock.yaml"
    "yarn.lock"
    "poetry.lock"
    "uv.lock"
    "Cargo.lock"
    "docker-compose*.yml"    # infra config
    "docker-compose*.yaml"
)

# ─── Protected path patterns ────────────────────────────────────────
PATH_PATTERNS=(
    "terraform/*"
    "*/terraform/*"
)

# ─── Check basename ─────────────────────────────────────────────────
for pattern in "${BASENAME_PATTERNS[@]}"; do
    if [[ "$BASENAME" == $pattern ]]; then
        echo "BLOCKED: '$FILE_PATH' matches protected pattern '$pattern'." >&2
        if [[ "$BASENAME" == .env* ]]; then
            echo "Use .env.example as a reference instead." >&2
        fi
        exit 2
    fi
done

# ─── Check full path ────────────────────────────────────────────────
for pattern in "${PATH_PATTERNS[@]}"; do
    if [[ "$FILE_PATH" == $pattern ]]; then
        echo "BLOCKED: '$FILE_PATH' matches protected path pattern '$pattern'." >&2
        exit 2
    fi
done

exit 0
