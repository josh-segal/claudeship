#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Workspace Setup — install dependencies
#
# Runs after the worktree is created and .env/.claude are copied.
# Edit the commands below to match your project's dependency tools.
#
# Environment: $WORKSPACE_PATH, $WORKSPACE_NAME, $MAIN_CHECKOUT
# ---------------------------------------------------------------------------

echo "Installing dependencies for workspace ${WORKSPACE_NAME}..."

# Python (uv) — uncomment or edit as needed
# if [ -f "$WORKSPACE_PATH/pyproject.toml" ]; then
#   (cd "$WORKSPACE_PATH" && uv sync)
# fi

# Node (npm) — uncomment or edit as needed
# if [ -f "$WORKSPACE_PATH/package.json" ]; then
#   (cd "$WORKSPACE_PATH" && npm install)
# fi

# Node in subdirectory — uncomment or edit as needed
# if [ -f "$WORKSPACE_PATH/frontend/package.json" ]; then
#   (cd "$WORKSPACE_PATH/frontend" && npm install)
# fi

echo "Setup complete."
