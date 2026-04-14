#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Workspace Teardown — stop Docker stack and clean up routing
#
# Runs before the worktree is removed.
#
# Environment: $WORKSPACE_PATH, $WORKSPACE_NAME, $MAIN_CHECKOUT
# ---------------------------------------------------------------------------

# === EDIT THESE to match your project (must match run.sh) ===

PROJECT_PREFIX="myapp"
BASE_COMPOSE="docker-compose.yml"
OVERRIDE_FILE="docker-compose.workspace.yml"

# === END EDIT SECTION ===

TRAEFIK_DYNAMIC="${HOME}/.config/traefik-dynamic"
PROJECT="${PROJECT_PREFIX}-${WORKSPACE_NAME}"

echo "Stopping workspace \"${WORKSPACE_NAME}\"..."

# 1. Stop Docker stack
docker compose -p "$PROJECT" down -v --remove-orphans 2>/dev/null || true

# 2. Remove Traefik routing config
if [ -f "$TRAEFIK_DYNAMIC/${PROJECT}.yml" ]; then
  rm "$TRAEFIK_DYNAMIC/${PROJECT}.yml"
  echo "Removed Traefik config for ${PROJECT}"
fi

# 3. Remove compose override from worktree
if [ -f "$WORKSPACE_PATH/$OVERRIDE_FILE" ]; then
  rm "$WORKSPACE_PATH/$OVERRIDE_FILE"
fi

echo "Workspace \"${WORKSPACE_NAME}\" stopped."
