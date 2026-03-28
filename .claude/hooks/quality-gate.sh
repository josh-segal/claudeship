#!/bin/bash
#
# quality-gate.sh — Stop hook for Claude Code
#
# After every agent turn, auto-formats changed files using
# whichever formatters are available in the project.
# Exit 0 = always let the agent proceed.
#

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

# ─── Collect changed files ───────────────────────────────────────────
CHANGED_FILES=$(
    {
        git diff --name-only HEAD 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u | while read -r f; do
        [ -f "$f" ] && echo "$f"
        true
    done
)

if [ -z "$CHANGED_FILES" ]; then
    exit 0
fi

# ─── JavaScript/TypeScript: Prettier ─────────────────────────────────
if [ -f "node_modules/.bin/prettier" ]; then
    echo "$CHANGED_FILES" | xargs npx prettier --write 2>/dev/null || true
fi

# ─── Python: Ruff ────────────────────────────────────────────────────
PY_FILES=$(echo "$CHANGED_FILES" | grep '\.py$' || true)
if [ -n "$PY_FILES" ]; then
    if [ -f ".venv/bin/ruff" ] || command -v ruff &>/dev/null; then
        echo "$PY_FILES" | xargs ruff format 2>/dev/null || true
        echo "$PY_FILES" | xargs ruff check --fix 2>/dev/null || true
    fi
fi

# ─── Go: gofmt ───────────────────────────────────────────────────────
GO_FILES=$(echo "$CHANGED_FILES" | grep '\.go$' || true)
if [ -n "$GO_FILES" ]; then
    if command -v gofmt &>/dev/null; then
        echo "$GO_FILES" | xargs gofmt -w 2>/dev/null || true
    fi
fi

# ─── Rust: rustfmt ───────────────────────────────────────────────────
RS_FILES=$(echo "$CHANGED_FILES" | grep '\.rs$' || true)
if [ -n "$RS_FILES" ]; then
    if command -v rustfmt &>/dev/null; then
        echo "$RS_FILES" | xargs rustfmt 2>/dev/null || true
    fi
fi

exit 0
