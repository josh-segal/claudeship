#!/bin/bash
#
# backup-init.sh — SessionStart hook
#
# Initializes a git repo inside the Claude config dir for versioned backups.
# Idempotent: skips if .git already exists.
# Exit 0 always (never block session start).
#

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Bail if git not installed
command -v git &>/dev/null || exit 0

# Bail if config dir doesn't exist yet
[ -d "$CONFIG_DIR" ] || exit 0

# Already initialized? Done.
[ -d "$CONFIG_DIR/.git" ] && exit 0

cd "$CONFIG_DIR" || exit 0

git init -q

cat > .gitignore << 'GITIGNORE'
# Transient / high-churn files
state.json
history.jsonl
projects/
shell-snapshots/
telemetry/
file-history/
debug/
paste-cache/
todos/
statsig/
.DS_Store
mcp-needs-auth-cache.json
GITIGNORE

git add -A
GIT_AUTHOR_NAME="claude-backup" GIT_AUTHOR_EMAIL="backup@local" \
GIT_COMMITTER_NAME="claude-backup" GIT_COMMITTER_EMAIL="backup@local" \
  git commit -q -m "Initial backup" 2>/dev/null || true

exit 0
