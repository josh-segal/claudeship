#!/bin/bash
#
# backup-pre-edit.sh — PreToolUse hook for Edit|Write
#
# Auto-commits config dir state before edits to files within it.
# Exit 0 always (never block).
#

if ! read -r -t 5 INPUT && [ -z "$INPUT" ]; then
    echo "[$(date '+%H:%M:%S.%3N')] $(basename "$0"): stdin read timed out" >> /tmp/claude-notifier.log
    exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# No file path? Bail.
[ -z "$FILE_PATH" ] && exit 0

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Resolve to absolute for comparison
REAL_FILE=$(realpath "$FILE_PATH" 2>/dev/null) || exit 0
REAL_CONFIG=$(realpath "$CONFIG_DIR" 2>/dev/null) || exit 0

# Fast bail: file not inside config dir
case "$REAL_FILE" in
    "$REAL_CONFIG"/*) ;;
    *) exit 0 ;;
esac

# No git repo? Bail (init hasn't run yet).
[ -d "$CONFIG_DIR/.git" ] || exit 0

cd "$CONFIG_DIR" || exit 0

# Check for changes (fast no-op if clean)
git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet HEAD 2>/dev/null && exit 0

RELATIVE="${REAL_FILE#$REAL_CONFIG/}"

git add -A
GIT_AUTHOR_NAME="claude-backup" GIT_AUTHOR_EMAIL="backup@local" \
GIT_COMMITTER_NAME="claude-backup" GIT_COMMITTER_EMAIL="backup@local" \
  git commit -q -m "Auto-backup before edit: $RELATIVE" 2>/dev/null || true

exit 0
