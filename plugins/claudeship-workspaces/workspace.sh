#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MAIN_CHECKOUT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$MAIN_CHECKOUT")"
WORKTREE_ROOT="$(dirname "$MAIN_CHECKOUT")/${REPO_NAME}-worktrees"
# Derive branch prefix from git user name (e.g. "Josh Segal" → "josh-segal")
BRANCH_PREFIX="$(git -C "$MAIN_CHECKOUT" config user.name 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
if [[ -z "$BRANCH_PREFIX" ]]; then
  echo "Error: git user.name is not set. Run: git config user.name \"Your Name\""
  exit 1
fi
BASE_BRANCH="main"

usage() {
  cat <<EOF
Usage: workspace.sh <command> [args]

Workspace lifecycle:
  up      <name>            Create worktree + branch, copy .env and .claude/
  destroy <name>            Remove worktree + branch
  context <name> [task]     Generate workspace CLAUDE.md and .workspace/ artifact stubs
  ls                        List all workspaces with branch and path
  status  <name>            Show detailed status for a workspace

Worktree root: $WORKTREE_ROOT
Branch format: $BRANCH_PREFIX/<name>
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------

ensure_not_worktree() {
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    local toplevel
    toplevel="$(git rev-parse --show-toplevel)"
    if [ "$toplevel" != "$MAIN_CHECKOUT" ]; then
      echo "Error: you're inside a worktree ($toplevel)."
      echo "Run workspace.sh from the main checkout: $MAIN_CHECKOUT"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Worktree helpers
# ---------------------------------------------------------------------------

worktree_path() {
  echo "$WORKTREE_ROOT/$1"
}

worktree_exists() {
  local name="$1"
  local wt_path
  wt_path="$(worktree_path "$name")"
  git -C "$MAIN_CHECKOUT" worktree list --porcelain | grep -q "^worktree $wt_path$"
}

create_worktree() {
  local name="$1"
  local branch="${BRANCH_PREFIX}/${name}"
  local wt_path
  wt_path="$(worktree_path "$name")"

  if worktree_exists "$name"; then
    echo "Worktree already exists: $wt_path"
    return 0
  fi

  mkdir -p "$WORKTREE_ROOT"

  # Create branch from base if it doesn't exist, then add worktree
  if git -C "$MAIN_CHECKOUT" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Creating worktree on existing branch: $branch"
    git -C "$MAIN_CHECKOUT" worktree add "$wt_path" "$branch"
  else
    echo "Creating worktree with new branch: $branch (from $BASE_BRANCH)"
    git -C "$MAIN_CHECKOUT" worktree add -b "$branch" "$wt_path" "$BASE_BRANCH"
  fi
}

remove_worktree() {
  local name="$1"
  local branch="${BRANCH_PREFIX}/${name}"
  local wt_path
  wt_path="$(worktree_path "$name")"

  if worktree_exists "$name"; then
    echo "Removing worktree: $wt_path"
    git -C "$MAIN_CHECKOUT" worktree remove "$wt_path" --force
  fi

  # Clean up the branch if it exists and is fully merged
  if git -C "$MAIN_CHECKOUT" show-ref --verify --quiet "refs/heads/$branch"; then
    if git -C "$MAIN_CHECKOUT" branch --merged "$BASE_BRANCH" | grep -q "$branch"; then
      echo "Deleting merged branch: $branch"
      git -C "$MAIN_CHECKOUT" branch -d "$branch"
    else
      echo "Branch $branch has unmerged changes — keeping it."
      echo "  Delete manually with: git branch -D $branch"
    fi
  fi
}


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_up() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Error: workspace name required. Usage: workspace.sh up <name>"
    exit 1
  fi

  ensure_not_worktree

  local wt_path
  wt_path="$(worktree_path "$name")"

  # 1. Create worktree + branch
  create_worktree "$name"

  # 2. Copy .env from main checkout
  if [ -f "$MAIN_CHECKOUT/.env" ]; then
    echo "Copying .env from main checkout"
    cp "$MAIN_CHECKOUT/.env" "$wt_path/.env"
  else
    echo "Warning: no .env in main checkout ($MAIN_CHECKOUT)"
    echo "  Create one or copy manually to $wt_path/.env"
  fi

  # 3. Copy .claude/ from main checkout (hooks + settings)
  # Note: CLAUDE.md is NOT copied here — use 'workspace.sh context <name>' to generate
  # a workspace-specific CLAUDE.md with task context injected.
  if [ -d "$MAIN_CHECKOUT/.claude" ]; then
    echo "Copying .claude/ from main checkout"
    cp -a "$MAIN_CHECKOUT/.claude" "$wt_path/.claude"
  fi

  echo ""
  echo "=== Workspace \"${name}\" created ==="
  echo "  Worktree:  $wt_path"
  echo "  Branch:    ${BRANCH_PREFIX}/${name}"
  echo ""
}

cmd_destroy() {
  local name="${1:?Error: workspace name required. Usage: workspace.sh destroy <name>}"

  # Remove worktree + branch
  remove_worktree "$name"

  echo "Workspace \"${name}\" destroyed."
}

cmd_status() {
  local name="${1:?Error: workspace name required. Usage: workspace.sh status <name>}"
  local branch="${BRANCH_PREFIX}/${name}"
  local wt_path
  wt_path="$(worktree_path "$name")"

  echo "=== Workspace: ${name} ==="
  echo ""

  if worktree_exists "$name"; then
    echo "  Worktree:  $wt_path"
    echo "  Branch:    $branch"
    local ahead behind
    ahead="$(git -C "$wt_path" rev-list "$BASE_BRANCH".."$branch" --count 2>/dev/null || echo "?")"
    behind="$(git -C "$wt_path" rev-list "$branch".."$BASE_BRANCH" --count 2>/dev/null || echo "?")"
    echo "  Commits:   $ahead ahead, $behind behind $BASE_BRANCH"
    local last_commit
    last_commit="$(git -C "$wt_path" log -1 --format='%h %s (%cr)' 2>/dev/null || echo "unknown")"
    echo "  Last:      $last_commit"
  else
    echo "  Worktree:  (not found)"
  fi

  echo ""
}

cmd_ls() {
  echo "Workspaces:"
  echo ""

  local found=false

  while IFS= read -r line; do
    # Parse porcelain output: "worktree /path/to/worktree"
    if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
      local wt_path="${BASH_REMATCH[1]}"

      # Skip the main checkout
      [ "$wt_path" = "$MAIN_CHECKOUT" ] && continue

      # Only show worktrees in our managed root
      [[ "$wt_path" == "$WORKTREE_ROOT"/* ]] || continue

      local name
      name="$(basename "$wt_path")"
      local branch="${BRANCH_PREFIX}/${name}"

      local last_commit
      last_commit="$(git -C "$wt_path" log -1 --format='%h (%cr)' 2>/dev/null || echo "unknown")"

      echo "  ${name}"
      echo "    Branch:  $branch"
      echo "    Commit:  $last_commit"
      echo "    Path:    $wt_path"
      echo ""
      found=true
    fi
  done < <(git -C "$MAIN_CHECKOUT" worktree list --porcelain)

  if [ "$found" = false ]; then
    echo "  (none)"
    echo ""
    echo "  Create one with: workspace.sh up <name>"
  fi
}

cmd_context() {
  local name="${1:?Error: workspace name required. Usage: workspace.sh context <name> [task]}"
  local task="${2:-}"
  local wt_path
  wt_path="$(worktree_path "$name")"
  local branch="${BRANCH_PREFIX}/${name}"
  local created_date
  created_date="$(date +%Y-%m-%d)"

  if ! worktree_exists "$name"; then
    echo "Error: workspace \"${name}\" does not exist. Run: workspace.sh up ${name}"
    exit 1
  fi

  echo "Generating workspace context for \"${name}\"..."

  # Generate workspace CLAUDE.md (prepend workspace block to main checkout's CLAUDE.md)
  local main_claude=""
  if [ -f "$MAIN_CHECKOUT/CLAUDE.md" ]; then
    main_claude="$(cat "$MAIN_CHECKOUT/CLAUDE.md")"
  fi

  local task_line="${task:-"(no task description provided — update this file with the task context)"}"

  cat > "$wt_path/CLAUDE.md" <<CLAUDEMD
<!-- Auto-generated workspace context — edit .workspace/plan.md and .workspace/research.md instead -->
## Active Workspace
- Name: ${name}
- Branch: ${branch}
- Created: ${created_date}

## Task
${task_line}

## Task Context
Read \`.workspace/research.md\` and \`.workspace/plan.md\` as initial proposals from setup.
Verify findings before acting on them — they may be incomplete or wrong.
Update these files as your understanding evolves.

---

${main_claude}
CLAUDEMD

  # Create .workspace/ artifact directory with labeled stubs
  mkdir -p "$wt_path/.workspace"

  if [ ! -f "$wt_path/.workspace/research.md" ]; then
    cat > "$wt_path/.workspace/research.md" <<'STUB'
# Research Notes

> **Status: stub** — populate this with codebase findings before opening the workspace session.
> Treat this as a starting point to verify, not ground truth.

## Relevant files


## Key observations


## Potential gotchas

STUB
  fi

  if [ ! -f "$wt_path/.workspace/plan.md" ]; then
    cat > "$wt_path/.workspace/plan.md" <<'STUB'
# Implementation Plan

> **Status: stub** — populate this with a proposed approach before opening the workspace session.
> Treat this as a starting point to verify, not a fixed spec. Update as understanding evolves.

## Approach


## Steps


## Open questions

STUB
  fi

  # Add .workspace/ to .gitignore in the worktree (ephemeral session artifacts)
  if [ -f "$wt_path/.gitignore" ]; then
    if ! grep -q "^\.workspace/$" "$wt_path/.gitignore" 2>/dev/null; then
      echo ".workspace/" >> "$wt_path/.gitignore"
    fi
  else
    echo ".workspace/" > "$wt_path/.gitignore"
  fi

  echo "Context generated:"
  echo "  CLAUDE.md:                  $wt_path/CLAUDE.md"
  echo "  .workspace/research.md:     $wt_path/.workspace/research.md"
  echo "  .workspace/plan.md:         $wt_path/.workspace/plan.md"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
  up)      shift; cmd_up "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  context) shift; cmd_context "$@" ;;
  status)  shift; cmd_status "$@" ;;
  ls)      cmd_ls ;;
  *)       usage ;;
esac
