# Dev & Release Workflows for Claudeship Monorepo

## Context

Claudeship was restructured into a monorepo with two plugins plus a macOS notifier. The dev and release workflows need to match. Current gaps: no dev-setup, stale plugin cache, manual cask SHA updates, no MCP auto-recompile, no version bump tooling, missing CLAUDE.md, release.yml references old paths, notifier source ships inside the plugin unnecessarily.

---

## 1. Move notifier + Casks to monorepo root

The notifier is distributed via Homebrew, not the Claude Code plugin. Move out of the plugin so it doesn't ship with installs.

```
plugins/claudeship/src/notifier/*  →  notifier/
plugins/claudeship/Casks/*         →  Casks/
```

Use `git mv` for each file. Delete empty source directories after.

**Files:**
- `git mv plugins/claudeship/src/notifier/ClaudeNotifier.swift notifier/ClaudeNotifier.swift`
- `git mv plugins/claudeship/src/notifier/Info.plist notifier/Info.plist`
- `git mv plugins/claudeship/src/notifier/rebuild-notifier.sh notifier/rebuild-notifier.sh`
- `git mv plugins/claudeship/src/notifier/install-notifier.sh notifier/install-notifier.sh`
- `git mv plugins/claudeship/Casks/claude-notifier.rb Casks/claude-notifier.rb`

**Update references:**
- `.claude/settings.json` — Swift rebuild hook path: `*src/notifier/ClaudeNotifier.swift` → `*notifier/ClaudeNotifier.swift`, script path → `$CLAUDE_PROJECT_DIR/notifier/rebuild-notifier.sh`
- `.github/workflows/release.yml` — `src/notifier/` → `notifier/`
- `.gitignore` — `plugins/claudeship/src/notifier/ClaudeNotifier` → `notifier/ClaudeNotifier`

---

## 2. Shell function for dev

Add to `~/.zshrc`:

```bash
claudeship-dev() {
  "$@" --plugin-dir ~/Coding/claudeship/plugins/claudeship \
       --plugin-dir ~/Coding/claudeship/plugins/claudeship-workspaces
}
```

Usage: `claudeship-dev claude-work`, `claudeship-dev claude-pers`, etc. Works from any repo. `--plugin-dir` overrides installed marketplace plugins with the same name, so dev source is used live — no symlinks, no cache manipulation.

First-time setup also needs:
- `cd plugins/claudeship-workspaces/mcp && npm install && npm run build`
- `bash notifier/install-notifier.sh` (if not already installed via Homebrew)

---

## 3. Version bump tooling

Adopt the superpowers pattern: `scripts/bump-version.sh` + `.version-bump.json`.

### `.version-bump.json` (create at repo root)

```json
{
  "files": [
    { "path": "plugins/claudeship/.claude-plugin/plugin.json", "field": "version" },
    { "path": "plugins/claudeship-workspaces/.claude-plugin/plugin.json", "field": "version" }
  ],
  "audit": {
    "exclude": [
      "CHANGELOG.md",
      "node_modules",
      ".git",
      ".version-bump.json",
      "scripts/bump-version.sh",
      "Casks/claude-notifier.rb"
    ]
  }
}
```

Note: `marketplace.json` does NOT have a version field per-plugin (just name/description/source), so it's not in the bump list.

### `scripts/bump-version.sh` (create)

Copy superpowers' script verbatim — it's MIT licensed, generic, and config-driven. No modifications needed. Commands:
- `scripts/bump-version.sh 0.0.2` — bump all declared files
- `scripts/bump-version.sh --check` — detect version drift
- `scripts/bump-version.sh --audit` — find missed version strings

---

## 4. Dev hooks update

File: `.claude/settings.json`

**Add MCP auto-recompile hook** (new PostToolUse entry):

```json
{
  "matcher": "Write|Edit",
  "hooks": [{
    "type": "command",
    "timeout": 30,
    "statusMessage": "Recompiling MCP workspace server...",
    "command": "jq -r '.tool_input.file_path // empty' | { read -r f; if [[ \"$f\" == *\"mcp/workspace-server.ts\" ]]; then cd \"$CLAUDE_PROJECT_DIR/plugins/claudeship-workspaces/mcp\" && npm run build; fi; } || true"
  }]
}
```

**Update existing Swift hook** — fix path to match new notifier location at monorepo root.

---

## 5. CI Workflows

### Update `.github/workflows/release.yml`

1. Fix source paths: `src/notifier/` → `notifier/`
2. Add auto-cask-update step after release creation:

```yaml
- name: Update Homebrew cask
  run: |
    VERSION="${{ steps.version.outputs.version }}"
    SHA="${{ steps.sha.outputs.sha256 }}"
    sed -i '' "s/version \".*\"/version \"$VERSION\"/" Casks/claude-notifier.rb
    sed -i '' "s/sha256 \".*\"/sha256 \"$SHA\"/" Casks/claude-notifier.rb
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git add Casks/claude-notifier.rb
    git commit -m "update cask to v$VERSION"
    git push origin HEAD:main
```

### New `.github/workflows/test.yml`

Trigger: push to main, PRs

```yaml
jobs:
  test-core:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: astral-sh/setup-uv@v5
      - run: cd plugins/claudeship && uv sync && uv run pytest
      - run: cd plugins/claudeship && uv run ruff check

  build-mcp:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: cd plugins/claudeship-workspaces/mcp && npm ci && npm run build
```

---

## 6. CLAUDE.md

Create at repo root. Content:

- Monorepo layout: `plugins/claudeship/`, `plugins/claudeship-workspaces/`, `notifier/`, `Casks/`, `scripts/`
- Dev: add `claudeship-dev` function to `.zshrc`, use `claudeship-dev claude-work` etc. from any repo
- First-time: `npm install && npm run build` in MCP dir, `bash notifier/install-notifier.sh`
- Auto-rebuild hooks: Swift edits → notifier rebuild, TS edits → MCP recompile (dev-only, in `.claude/settings.json`)
- Releasing: `scripts/bump-version.sh 0.0.2`, commit, tag, push → CI builds notifier + auto-updates cask
- ClaudeNotifier: source at `notifier/`, distributed via Homebrew cask, NOT part of the plugin. Logs: `tail -f /tmp/claude-notifier.log`

---

## Files summary

| File | Action |
|---|---|
| `notifier/` | **Create dir** (move 4 files from `plugins/claudeship/src/notifier/`) |
| `Casks/` | **Move** from `plugins/claudeship/Casks/` |
| `plugins/claudeship/src/notifier/` | **Delete** (emptied by move) |
| `plugins/claudeship/Casks/` | **Delete** (emptied by move) |
| `scripts/bump-version.sh` | **Create** (from superpowers pattern) |
| `.version-bump.json` | **Create** |
| `CLAUDE.md` | **Create** |
| `~/.zshrc` | **Edit** — add `claudeship-dev` function |
| `.github/workflows/release.yml` | **Edit** — fix paths, add cask auto-update |
| `.github/workflows/test.yml` | **Create** |
| `.claude/settings.json` | **Edit** — add MCP hook, fix Swift hook path |
| `.gitignore` | **Edit** — update notifier binary path |

---

## Verification

1. `claudeship-dev claude-work` from another repo — both plugins load, skills/hooks work
2. Edit `notifier/ClaudeNotifier.swift` in claudeship repo — hook auto-rebuilds
3. Edit `mcp/workspace-server.ts` in claudeship repo — hook auto-recompiles
4. `scripts/bump-version.sh --check` — versions in sync
5. `scripts/bump-version.sh 0.0.2` — both plugin.json files updated
6. `git tag v0.0.2 && git push --tags` — CI builds notifier, creates release, auto-updates cask
7. `cd plugins/claudeship && uv run pytest` — tests pass
