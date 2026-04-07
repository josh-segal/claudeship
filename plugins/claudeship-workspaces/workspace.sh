#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MAIN_CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_ROOT="$(dirname "$MAIN_CHECKOUT")/next-chief-of-staff-worktrees"
# Derive branch prefix from git user name (e.g. "Josh Segal" → "josh-segal")
BRANCH_PREFIX="$(git -C "$MAIN_CHECKOUT" config user.name 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
if [[ -z "$BRANCH_PREFIX" ]]; then
  echo "Error: git user.name is not set. Run: git config user.name \"Your Name\""
  exit 1
fi
BASE_BRANCH="dev"

BASE_COMPOSE="docker-compose.yml"
OVERRIDE_FILE="docker-compose.workspace.yml"
TRAEFIK_DYNAMIC="${HOME}/.config/traefik-dynamic"
TRAEFIK_COMPOSE="$TRAEFIK_DYNAMIC/docker-compose.traefik.yml"

usage() {
  cat <<EOF
Usage: workspace.sh <command> [args]

Workspace lifecycle:
  up      <name>            Create worktree + branch, install deps, start Docker stack
  down    <name>            Stop Docker stack (worktree remains)
  destroy <name>            Stop Docker stack and remove worktree + branch
  context <name> [task]     Generate workspace CLAUDE.md and .workspace/ artifact stubs
  ls                        List all workspaces with status, branch, and URLs
  logs    <name>            Tail Docker logs for a workspace
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
# Docker / Traefik helpers
# ---------------------------------------------------------------------------

ensure_traefik() {
  mkdir -p "$TRAEFIK_DYNAMIC"

  cat > "$TRAEFIK_COMPOSE" <<YAML
services:
  traefik:
    image: traefik:v3.4
    command:
      - "--api.insecure=true"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - ${TRAEFIK_DYNAMIC}:/etc/traefik/dynamic:ro
    networks:
      - traefik-public
    restart: unless-stopped

networks:
  traefik-public:
    name: traefik-public
YAML

  if ! docker compose -f "$TRAEFIK_COMPOSE" -p traefik ps --status running 2>/dev/null | tail -n +2 | grep -q .; then
    echo "Starting Traefik reverse proxy..."
    docker compose -f "$TRAEFIK_COMPOSE" -p traefik up -d
  fi
}

generate_traefik_config() {
  local name="$1"
  local project="cos-${name}"
  mkdir -p "$TRAEFIK_DYNAMIC"
  cat > "$TRAEFIK_DYNAMIC/cos-${name}.yml" <<YAML
http:
  routers:
    cos-${name}-api:
      rule: "Host(\`api-cos-${name}.lvh.me\`)"
      entryPoints:
        - web
      service: cos-${name}-api
    cos-${name}-frontend:
      rule: "Host(\`cos-${name}.lvh.me\`)"
      entryPoints:
        - web
      service: cos-${name}-frontend
    cos-${name}-phoenix:
      rule: "Host(\`phoenix-cos-${name}.lvh.me\`)"
      entryPoints:
        - web
      service: cos-${name}-phoenix

  services:
    cos-${name}-api:
      loadBalancer:
        servers:
          - url: "http://${project}-api-1:8000"
    cos-${name}-frontend:
      loadBalancer:
        servers:
          - url: "http://${project}-frontend-1:80"
    cos-${name}-phoenix:
      loadBalancer:
        servers:
          - url: "http://${project}-phoenix-1:6006"
YAML
}

generate_override() {
  local name="$1"
  local wt_path="$2"
  cat > "$wt_path/$OVERRIDE_FILE" <<YAML
# Auto-generated workspace override for "${name}" — do not commit
services:
  api:
    ports: !override []
    networks:
      - default
      - traefik-public

  frontend:
    ports: !override []
    networks:
      - default
      - traefik-public

  phoenix:
    ports: !override []
    networks:
      - default
      - traefik-public

  redis:
    ports: !override []

  postgres:
    ports: !override []

networks:
  traefik-public:
    external: true
YAML
}

is_stack_running() {
  local project="$1"
  docker compose -p "$project" ps --status running 2>/dev/null | tail -n +2 | grep -q .
}

print_urls() {
  local name="$1"
  local wt_path="$2"
  echo ""
  echo "=== Workspace \"${name}\" is ready ==="
  echo "  Worktree:  $wt_path"
  echo "  Branch:    ${BRANCH_PREFIX}/${name}"
  echo "  Frontend:  http://cos-${name}.lvh.me"
  echo "  API:       http://api-cos-${name}.lvh.me"
  echo "  Phoenix:   http://phoenix-cos-${name}.lvh.me"
  echo "  Traefik:   http://localhost:8080"
  echo ""
  echo "  cd $wt_path  # to start working"
  echo ""
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

  local project="cos-${name}"
  local wt_path
  wt_path="$(worktree_path "$name")"

  # Check if Docker stack is already running
  if is_stack_running "$project"; then
    read -rp "Stack \"${name}\" is already running. Rebuild? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  # 1. Create worktree + branch
  create_worktree "$name"

  # 2. Ensure Traefik is up
  ensure_traefik

  # 3. Install dependencies in the worktree
  echo "Installing dependencies..."
  if [ -f "$wt_path/pyproject.toml" ]; then
    (cd "$wt_path" && uv sync 2>/dev/null || true)
  fi
  if [ -f "$wt_path/frontend/package.json" ]; then
    (cd "$wt_path/frontend" && npm install 2>/dev/null || true)
  fi

  # 4. Copy .env from main checkout
  if [ -f "$MAIN_CHECKOUT/.env" ]; then
    echo "Copying .env from main checkout"
    cp "$MAIN_CHECKOUT/.env" "$wt_path/.env"
  else
    echo "Warning: no .env in main checkout ($MAIN_CHECKOUT)"
    echo "  Create one or copy manually to $wt_path/.env"
  fi

  # 5. Copy .claude/ from main checkout (hooks + settings)
  # Note: CLAUDE.md is NOT copied here — use 'workspace.sh context <name>' to generate
  # a workspace-specific CLAUDE.md with task context injected.
  if [ -d "$MAIN_CHECKOUT/.claude" ]; then
    echo "Copying .claude/ from main checkout"
    cp -a "$MAIN_CHECKOUT/.claude" "$wt_path/.claude"
  fi

  # 6. Generate compose override and Traefik routing config
  generate_override "$name" "$wt_path"
  generate_traefik_config "$name"

  # 7. Start the stack from the worktree directory
  echo "Starting workspace \"${name}\"..."
  (cd "$wt_path" && docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_FILE" -p "$project" up -d --build)

  # 8. Wait for Postgres + Redis health checks
  echo "Waiting for services..."
  local retries=15
  while [ $retries -gt 0 ]; do
    local pg_healthy redis_healthy
    pg_healthy=$(cd "$wt_path" && docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_FILE" -p "$project" ps postgres 2>/dev/null | grep -c "healthy" || true)
    redis_healthy=$(cd "$wt_path" && docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_FILE" -p "$project" ps redis 2>/dev/null | grep -c "healthy" || true)
    if [ "$pg_healthy" -gt 0 ] && [ "$redis_healthy" -gt 0 ]; then
      break
    fi
    retries=$((retries - 1))
    sleep 2
  done

  # 9. Print URLs
  print_urls "$name" "$wt_path"
}

cmd_down() {
  local name="${1:?Error: workspace name required. Usage: workspace.sh down <name>}"
  local project="cos-${name}"

  echo "Stopping workspace \"${name}\"..."
  docker compose -p "$project" down -v --remove-orphans

  # Clean up Traefik config
  if [ -f "$TRAEFIK_DYNAMIC/cos-${name}.yml" ]; then
    rm "$TRAEFIK_DYNAMIC/cos-${name}.yml"
  fi

  local wt_path
  wt_path="$(worktree_path "$name")"

  # Clean up override file in worktree
  if [ -f "$wt_path/$OVERRIDE_FILE" ]; then
    rm "$wt_path/$OVERRIDE_FILE"
  fi

  echo "Workspace \"${name}\" stopped. Worktree remains at: $wt_path"
}

cmd_destroy() {
  local name="${1:?Error: workspace name required. Usage: workspace.sh destroy <name>}"
  local project="cos-${name}"

  # Stop Docker first
  if is_stack_running "$project"; then
    cmd_down "$name"
  fi

  # Remove worktree + branch
  remove_worktree "$name"

  echo "Workspace \"${name}\" destroyed."
}

cmd_logs() {
  local name="${1:?Error: workspace name required. Usage: workspace.sh logs <name>}"
  local project="cos-${name}"

  docker compose -p "$project" logs -f --tail 100
}

cmd_status() {
  local name="${1:?Error: workspace name required. Usage: workspace.sh status <name>}"
  local project="cos-${name}"
  local branch="${BRANCH_PREFIX}/${name}"
  local wt_path
  wt_path="$(worktree_path "$name")"

  echo "=== Workspace: ${name} ==="
  echo ""

  # Worktree info
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

  # Docker status
  if is_stack_running "$project"; then
    echo "  Docker:    running"
    echo "  Frontend:  http://cos-${name}.lvh.me"
    echo "  API:       http://api-cos-${name}.lvh.me"
    echo "  Phoenix:   http://phoenix-cos-${name}.lvh.me"
  else
    echo "  Docker:    stopped"
  fi

  echo ""
}

cmd_ls() {
  echo "Workspaces:"
  echo ""

  local found=false

  # List all worktrees (not just running Docker stacks)
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
      local project="cos-${name}"
      local branch="${BRANCH_PREFIX}/${name}"

      local docker_status="stopped"
      if is_stack_running "$project"; then
        docker_status="running"
      fi

      local last_commit
      last_commit="$(git -C "$wt_path" log -1 --format='%h (%cr)' 2>/dev/null || echo "unknown")"

      echo "  ${name}"
      echo "    Branch:    $branch"
      echo "    Commit:    $last_commit"
      echo "    Docker:    $docker_status"
      if [ "$docker_status" = "running" ]; then
        echo "    Frontend:  http://cos-${name}.lvh.me"
        echo "    API:       http://api-cos-${name}.lvh.me"
        echo "    Phoenix:   http://phoenix-cos-${name}.lvh.me"
      fi
      echo "    Path:      $wt_path"
      echo ""
      found=true
    fi
  done < <(git -C "$MAIN_CHECKOUT" worktree list --porcelain)

  # Also check for Traefik configs without worktrees (legacy/orphaned)
  for config in "$TRAEFIK_DYNAMIC"/cos-*.yml; do
    [ -f "$config" ] || continue
    local cfg_name
    cfg_name="$(basename "$config" .yml)"
    cfg_name="${cfg_name#cos-}"  # strip cos- prefix
    local cfg_wt_path
    cfg_wt_path="$(worktree_path "$cfg_name")"

    # Skip if we already listed this workspace via worktree
    if [ -d "$cfg_wt_path" ]; then
      continue
    fi

    local cfg_project="cos-${cfg_name}"
    if is_stack_running "$cfg_project"; then
      echo "  ${cfg_name} (orphaned — no worktree)"
      echo "    Docker:    running"
      echo "    Frontend:  http://cos-${cfg_name}.lvh.me"
      echo "    API:       http://api-cos-${cfg_name}.lvh.me"
      echo ""
      found=true
    fi
  done

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
- Frontend: http://cos-${name}.lvh.me
- API: http://api-cos-${name}.lvh.me
- Phoenix: http://phoenix-cos-${name}.lvh.me
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
  down)    shift; cmd_down "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  context) shift; cmd_context "$@" ;;
  logs)    shift; cmd_logs "$@" ;;
  status)  shift; cmd_status "$@" ;;
  ls)      cmd_ls ;;
  *)       usage ;;
esac
