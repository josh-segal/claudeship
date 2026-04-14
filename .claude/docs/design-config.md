# Configuration System Design

Settled design for user-configurable commands, terminal integration, and workspace
lifecycle across claudeship. Supersedes open questions 1-3 in `config-thinking.md`.

Informed by Conductor's approach: project config is just lifecycle scripts, not
service definitions. The project owns its setup/run/teardown logic — claudeship
provides the worktree scaffolding and terminal integration around it.

---

## Two Config Layers

| File | Scope | Committed? | Purpose |
|------|-------|------------|---------|
| `~/.claude/claudeship.json` | User / machine | No | Personal defaults: terminal, claude command fallback |
| `.claudeship.json` (repo root) | Project | Yes | Claude command override, workspace lifecycle scripts |

### Override Chain

```
.claudeship.json (project)  >  ~/.claude/claudeship.json (user)  >  built-in defaults
```

Project config wins when present. User config is the fallback. Built-in defaults
cover the rest. One exception: `terminal` is user-only — it's a machine property,
not a project property, and is never read from project config.

**Why two layers?** The claude command can go either way — a solo dev pins it
per-project, a team omits it and lets each member's personal default kick in.
Lifecycle scripts are always project-level because they encode what the repo needs
(install deps, start services, clean up). Terminal choice follows the machine.

---

## User-Level: `~/.claude/claudeship.json`

Lives alongside `accounts.json` and `state.json` — same tree, no new config directory.

```jsonc
{
  // Terminal emulator for workspace_open tab creation.
  // Auto-detected from $TERM_PROGRAM if omitted.
  // Supported: "ghostty", "iterm2"
  // Anything else falls back to detached spawn (no tab).
  "terminal": "ghostty",

  "commands": {
    // Default CLI command/alias for launching Claude Code.
    // Used when the project .claudeship.json doesn't specify one.
    // Default: "claude"
    "claude": "claude-work"
  }
}
```

### How Users Set It

Primary: `/claudeship:setup` skill asks "What command do you use to launch Claude
Code?" and writes the file. Follows the Claude Code Native principle from
`config-thinking.md`.

Secondary: direct JSON editing — the schema is small enough to hand-edit.

---

## Project-Level: `.claudeship.json`

Lives at the repo root. Committed and shared with the team.

```jsonc
{
  "commands": {
    // Overrides the user-level claude command for this project.
    // Omit to let each team member's personal default apply.
    "claude": "claude-work"
  },

  "workspace": {
    "lifecycle": {
      // Shell commands run at specific points in the workspace lifecycle.
      // Each runs in the worktree directory.
      // Environment: $WORKSPACE_PATH, $WORKSPACE_NAME, $MAIN_CHECKOUT
      //
      // setup  — runs after worktree is created (install deps, copy .env, build)
      // run    — starts dev services (docker compose up, npm run dev, etc.)
      // teardown — runs before worktree is removed (stop services, cleanup)
      //
      // All are optional. Failure is reported but does not block the lifecycle step.

      "setup": "",
      "run": "",
      "teardown": ""
    }
  }
}
```

### Lifecycle Flow

```
workspace_create
  1. git worktree + branch created
  2. .claude/ and .env copied from main checkout
  3. .workspace/ artifact stubs generated
  4. *** lifecycle.setup runs ***    (npm install, pip install, etc.)
  5. *** lifecycle.run runs ***      (docker compose up -d, npm run dev, etc.)
  6. return success with worktree path

workspace_open
  1. New terminal tab opened with configured claude command
  2. return success

workspace_destroy
  1. *** lifecycle.teardown runs *** (docker compose down, cleanup, etc.)
  2. Worktree + branch removed
  3. return success
```

### What Moves Out of workspace.sh

The current `workspace.sh` hardcodes next-chief-of-staff-specific logic that
becomes project-owned lifecycle scripts:

| Currently hardcoded | Becomes |
|---------------------|---------|
| `uv sync` + `npm install` in `frontend/` | `lifecycle.setup` |
| Docker Compose up with `cos-` prefix, Traefik routing, service URLs | `lifecycle.run` |
| Health checks for postgres + redis | `lifecycle.run` (project's script waits for its own services) |
| Docker Compose override generation for api/frontend/phoenix | `lifecycle.run` or a project-owned script it calls |
| Docker Compose down + Traefik config cleanup | `lifecycle.teardown` |

What stays in workspace.sh (generic):
- Worktree creation/removal
- Branch management
- `.env` and `.claude/` copying
- `.workspace/` artifact generation (CLAUDE.md, research.md, plan.md)

### Environment Variables

Scripts receive context about where they're running:

| Variable | Value | Example |
|----------|-------|---------|
| `$WORKSPACE_PATH` | Worktree directory | `/path/to/project-worktrees/auth-refactor` |
| `$WORKSPACE_NAME` | Workspace name | `auth-refactor` |
| `$MAIN_CHECKOUT` | Original repo root | `/path/to/project` |

### Example: next-chief-of-staff

The current hardcoded workspace.sh logic becomes:

```jsonc
// next-chief-of-staff/.claudeship.json
{
  "commands": {
    "claude": "claude-work"
  },
  "workspace": {
    "lifecycle": {
      "setup": "bash .claudeship/setup.sh",
      "run": "bash .claudeship/run.sh",
      "teardown": "bash .claudeship/teardown.sh"
    }
  }
}
```

Where `.claudeship/setup.sh` handles `uv sync` + `npm install`, `.claudeship/run.sh`
handles Docker Compose + Traefik + health checks, and `.claudeship/teardown.sh`
handles Docker Compose down + cleanup. The scripts are project-owned and committed.

Alternatively, simple projects inline everything:

```jsonc
// simple-node-app/.claudeship.json
{
  "workspace": {
    "lifecycle": {
      "setup": "npm install",
      "run": "npm run dev",
      "teardown": ""
    }
  }
}
```

---

## Reading Strategy

The MCP server reads both files synchronously on each tool invocation via
`readFileSync` with try/catch fallback to empty objects. No caching, no file
watchers, no daemon reload. Both files are tiny and read infrequently.

```typescript
interface ClaudeshipConfig {
  terminal?: string;
  commands?: {
    claude?: string;
  };
  workspace?: {
    lifecycle?: {
      setup?: string;
      run?: string;
      teardown?: string;
    };
  };
}

function loadUserConfig(): ClaudeshipConfig {
  try {
    const p = path.join(process.env.HOME ?? "", ".claude", "claudeship.json");
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return {};
  }
}

function loadProjectConfig(): ClaudeshipConfig {
  try {
    const p = path.join(MAIN_CHECKOUT, ".claudeship.json");
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return {};
  }
}

function resolveConfig(): ClaudeshipConfig {
  const user = loadUserConfig();
  const project = loadProjectConfig();

  return {
    // terminal is user-only, never from project
    terminal: user.terminal ?? process.env.TERM_PROGRAM?.toLowerCase(),

    commands: {
      // project wins, then user, then default
      claude: project.commands?.claude ?? user.commands?.claude ?? "claude",
    },

    // lifecycle comes from project only
    workspace: project.workspace,
  };
}
```

---

## Built-in Defaults

| Key | Default | Source |
|-----|---------|--------|
| `terminal` | `$TERM_PROGRAM` | Auto-detect at runtime |
| `commands.claude` | `"claude"` | Standard binary name |
| `workspace.lifecycle.*` | `""` (no-op) | Empty = skip |

If neither file exists, everything works with zero config.

---

## `workspace_open` Implementation

```typescript
case "workspace_open": {
  const wsName = args?.name as string;
  const wt = worktreePath(wsName);

  if (!worktreeExists(wsName)) { /* error */ }

  const cfg = resolveConfig();
  const claudeCmd = cfg.commands?.claude ?? "claude";
  const terminal = cfg.terminal ?? "";

  if (process.platform === "darwin" && terminal === "ghostty") {
    execSync(`osascript -e '
      tell application "Ghostty"
        activate
        set cfgAS to new surface configuration
        set initial working directory of cfgAS to "${wt}"
        set command of cfgAS to "${claudeCmd}"
        set t to new tab in front window with configuration cfgAS
      end tell
    '`);
  } else {
    // Fallback: detached spawn (Linux, unsupported terminal)
    const child = spawn(claudeCmd, [wt], {
      detached: true, stdio: "ignore", shell: true,
    });
    child.unref();
  }

  return { /* success */ };
}
```

---

## Starters

Reusable lifecycle script sets that users copy into their projects. Starters
live in `starters/` in the claudeship repo and provide pre-built `.claudeship.json`
+ `.claudeship/` scripts for common project shapes.

### Available Starters

| Starter | Directory | What it does |
|---------|-----------|-------------|
| Docker + Traefik | `starters/docker-traefik/` | Shared Traefik reverse proxy, per-workspace Docker Compose routing via `*.lvh.me`, health checks |

### How Users Apply a Starter

```bash
cp -r starters/docker-traefik/.claudeship .claudeship/
cp starters/docker-traefik/.claudeship.json .claudeship.json
# Edit .claudeship/*.sh to match project's services and ports
```

### Creating New Starters

A starter is a directory containing:
- `.claudeship.json` — lifecycle config pointing to scripts
- `.claudeship/` — the lifecycle scripts (setup.sh, run.sh, teardown.sh)
- `README.md` — what it does, prerequisites, which variables to edit

Scripts should have a clearly marked `=== EDIT THESE ===` section at the top
with project-specific variables (service names, ports, prefixes). The rest of
the script should work generically.

---

## Future Extensibility

- **New user prefs** (notification sounds, status bar verbosity, icons) become
  top-level keys in `~/.claude/claudeship.json`.

- **New lifecycle scripts** (e.g. `test`, `lint`) get added to
  `workspace.lifecycle` in `.claudeship.json`.

- **New project-level sections** (quality gate config, MCP toggles) become siblings
  to `workspace` in `.claudeship.json`.

- **New terminal support** is one `else if` branch in `workspace_open` plus adding
  the name to the supported values for `terminal`.

The two-file split means user prefs and project config evolve independently.
