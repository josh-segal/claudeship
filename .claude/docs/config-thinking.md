# Config Architecture — Open Questions & Food for Thought

This is a living document capturing open questions about how configuration should work
across the claudeship tooling. The goal is not to answer everything now, but to let
patterns emerge as more tools are built before committing to a structure.

---

## Guiding Principle: Claude Code Native

Everything in this setup — first-time install, changing config, switching terminals,
enabling/disabling features — should feel native to Claude Code itself. That means
using Claude Code's own input primitives (`AskUserQuestion`, selection boxes, plan
approval flows) rather than shell prompts, interactive scripts, or external config
editors. A user should be able to type "change my terminal to iTerm2" and have Claude
handle it end-to-end: read the current config, present the choice, write the update,
restart affected services. This applies to both the initial setup wizard and any
subsequent reconfiguration.

---

## Open Questions

### 1. Where does config live?

**Current assumption:** `~/.claude/notifier.json` — user-level, outside the repo,
written by the install process.

**Open:**
- Does user-level (`~/.claude/`) vs project-level (`.claude/` in the repo) matter?
  The claudeship repo is itself a setup repo, so the line is blurry.
- Should there be a single unified config file for all claudeship tools, or per-tool
  files? A single file is easier to reason about but grows unwieldy. Per-tool files
  are modular but scatter config.
- Should config be checked into the repo (with user-specific values gitignored) or
  always outside the repo?

---

### 2. What belongs in config vs code?

**Things currently hardcoded that are clearly config:**
- Terminal app name + bundle ID (used in `stop.sh` and the Swift daemon)
- Notification sounds per event type (Ping, Basso — scattered across hook scripts)
- Socket path (`/tmp/claude-notifier.sock`)
- Daemon log path (`/tmp/claude-notifier.log`)

**Things that might become config as more tools are added:**
- Which hooks are active (opt-in/opt-out per hook type)
- Quality gate formatters (which ones to run, in what order)
- Workspace Docker stack defaults
- MCP server enablement

**Open:**
- Is there a meaningful split between "user preferences" (terminal, sounds) and
  "system config" (socket path, log path)? Or is that over-engineering?

---

### 3. How does config get read?

**Current dependency landscape:**
- Shell scripts already use `python3` for JSON parsing — reading a config file there
  is free.
- Swift daemon reads JSON natively via `JSONSerialization`.
- A config change currently requires a daemon restart to take effect.

**Open:**
- Should the daemon support a reload signal (e.g. `SIGHUP`) to re-read config without
  a full restart? Useful for sound/terminal changes.
- Should shell scripts read config on every invocation (adds latency) or should the
  daemon serve config over the socket (adds complexity)?
- Do we need a `notifier config get <key>` / `notifier config set <key> <value>` CLI
  interface, or is direct JSON editing (guided by Claude) sufficient?

---

### 4. What does the setup wizard look like?

**Current state:** `install-notifier.sh` — a bash script that compiles, signs, and
loads the LaunchAgent. It's functional but not Claude Code native.

**Aspirational:** A Claude Code session that walks through setup interactively:
- Detects what's already installed and what needs configuring
- Uses `AskUserQuestion` to present terminal choices, sound preferences, etc.
- Writes config, compiles, loads services — all within the Claude Code UI
- Validates the result (sends a test notification, checks daemon health)

**Self-testing pattern (settled):** Two tiers of verification:
1. **Automated** — daemon running, socket accepting connections, LaunchAgent loaded,
   binary executable, hooks present, settings.json valid, `--test` flag on the binary
   sends a notification and waits for `UNUserNotificationCenter` to confirm acceptance
   (programmatic delivery confirmation without human eyes)
2. **Visual** — one `AskUserQuestion` at the end: "did you see the banner?" — catches
   System Settings misconfiguration, Focus modes, wrong icon. If no, surface a
   diagnostic checklist. This is the only human step in the flow.

The `--test` flag is the key — it pushes delivery confirmation into the automated tier,
so the single human question is a true last-mile check rather than the only check.

**Open:**
- How much of the install process can be driven by Claude vs requires raw shell
  execution? Compilation (`swiftc`) and `launchctl` calls need shell, but the
  decision-making and user interaction could be entirely in Claude.
- Should there be a single "setup" slash command (e.g. `/setup-claudeship`) that
  drives the whole flow?
- How do we handle re-running setup (partial installs, terminal changes, upgrades)?
  Idempotency matters.

---

### 5. Portability for other users

**Known friction points today:**
- Terminal bundle ID hardcoded in Swift daemon source
- Ghostty app name hardcoded in `stop.sh`
- No guided first-run experience

**Open:**
- What's the minimum viable portable setup? Is it "clone repo, run one command, answer
  a few Claude-native questions"?
- How do we handle users without Ghostty at all (Terminal.app, no bell behavior)?
- Should the tool auto-detect the running terminal rather than asking? Detection is
  possible via `NSWorkspace` but has edge cases (multiple terminals open, terminal
  started by a different process, etc.).

---

## Things to Watch As More Tools Are Built

- Every new tool that needs config will reveal whether the current approach scales
- The quality gate formatter list, workspace Docker defaults, and MCP server config
  are all early signals of what "project-level" config looks like vs user-level
- The pattern for how Claude Code native reconfiguration works will become clearer
  once there are 2-3 tools that need it — resist designing the abstraction before then
