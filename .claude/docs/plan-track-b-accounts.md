# Track B — Accounts Implementation Plan

## Goal
Per-session account tracking. Shell aliases are the switching mechanism — no global
`active_account` concept. ClaudeNotifier shows per-session account dots in the panel
and account dots for working sessions in the statusline.

## Files to Create/Edit
- `~/.claude/accounts.json` — example/starter file (user's machine, not repo)
- `.claude/tools/accounts.py` — account registry CLI
- `.claude/hooks/notifications/notify-session-register.sh` — add account detection
- `.claude/tools/ClaudeNotifier.swift` — significant additions (see below)

---

## Accounts File: `~/.claude/accounts.json`

Lives at `~/.claude/accounts.json` (user-level, not in repo).
Create an example at `.claude/docs/accounts.example.json` in the repo for reference.

### Schema
```json
{
  "accounts": {
    "personal": {
      "display_name": "Personal",
      "config_dir": "~/.claude",
      "color": "blue"
    },
    "work": {
      "display_name": "Work",
      "config_dir": "~/.claude-work",
      "color": "green"
    },
    "edu": {
      "display_name": "Edu",
      "config_dir": "~/.claude-edu",
      "color": "orange"
    }
  }
}
```

Valid colors: `blue`, `green`, `orange`, `red`, `purple`, `yellow`
`config_dir` supports `~` expansion.
`display_name` is shown in the panel.

---

## 1. `.claude/tools/accounts.py`

### Commands
```
accounts.py list                                        # show all accounts, mark current
accounts.py add <name> --config-dir <path> --color <c> [--display-name <n>]
accounts.py remove <name>
accounts.py current                                     # detect from CLAUDE_CONFIG_DIR
```

### Account detection logic
Used by both `current` and `notify-session-register.sh`.

```python
def detect_current_account(accounts: dict) -> str | None:
    """Match CLAUDE_CONFIG_DIR env var against accounts registry."""
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    config_dir = os.path.realpath(os.path.expanduser(config_dir))
    for name, info in accounts.items():
        registered = os.path.realpath(os.path.expanduser(info.get("config_dir", "")))
        if registered == config_dir:
            return name
    return None
```

Use `os.path.realpath` on both sides to resolve symlinks — prevents false negatives.

### `list` output
```
  Accounts
  ─────────────────────────────
  ● personal   Personal    ~/.claude        alias: claude
  ○ work       Work        ~/.claude-work   alias: claude-work
  ○ edu        Edu         ~/.claude-edu    alias: claude-edu

  Add to your shell profile:
    alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'
    alias claude-edu='CLAUDE_CONFIG_DIR=~/.claude-edu claude'
```

- `●` = current (detected via CLAUDE_CONFIG_DIR), `○` = others
- Alias suggestions: if config_dir is `~/.claude`, alias is `claude` (no CLAUDE_CONFIG_DIR needed).
  Otherwise: `CLAUDE_CONFIG_DIR=<dir> claude`
- Alias name derived from account name: `work` → `claude-work`, `edu` → `claude-edu`, `personal` → `claude`

### `add` command
- Validates `--config-dir` exists (`os.path.isdir`)
- Validates `--color` is one of the valid set
- `--display-name` defaults to capitalized `<name>` if omitted
- Reads accounts.json if exists, adds entry, writes back
- Prints suggested alias to add to shell profile

### `remove` command
- Removes entry from accounts.json
- Warns if removing current account (detected via CLAUDE_CONFIG_DIR)

### `current` command
- Prints account name or "(unknown)" if no match found
- Exit code 0 in both cases

### File location for accounts.json
```python
ACCOUNTS_PATH = os.path.expanduser("~/.claude/accounts.json")
```

### Import state.py
```python
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from state import read_state  # only needed if future commands read state.json
```
accounts.py does NOT write to state.json — it only manages accounts.json.
state.py is imported for consistency but not required for this track.

### After writing accounts.json, notify ClaudeNotifier
Send `accounts_changed` socket message so the daemon reloads without restart:
```python
import socket as sock

def notify_daemon():
    path = "/tmp/claude-notifier.sock"
    if not os.path.exists(path):
        return
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.connect(path)
        s.sendall(json.dumps({"type": "accounts_changed"}).encode())
        s.close()
    except Exception:
        pass  # daemon not running, that's fine
```
Call `notify_daemon()` after any `add` or `remove`.

---

## 2. `notify-session-register.sh` — Add Account Detection

Current file location: `.claude/hooks/notifications/notify-session-register.sh`

### What to add
After reading `session_id` and `cwd` from the hook input, also detect the current
account name by reading `$CLAUDE_CONFIG_DIR` and matching against `~/.claude/accounts.json`.
Include `account` in the payload sent to the daemon.

### Current payload (existing, do not break):
```json
{
  "type": "session_register",
  "session_id": "...",
  "cwd": "...",
  "source": "startup"
}
```

### New payload (add `account` key):
```json
{
  "type": "session_register",
  "session_id": "...",
  "cwd": "...",
  "source": "startup",
  "account": "work"
}
```
`account` is an empty string `""` if accounts.json doesn't exist or no match found.
The daemon treats `""` the same as absent — no dot rendered.

### Implementation — replace the python3 block in the existing script:

```bash
#!/bin/bash
#
# notify-session-register.sh — SessionStart hook
#
# Fires when a Claude session begins or resumes. Registers the session
# with the daemon so it appears in the menu bar session list.
#

SOCK="/tmp/claude-notifier.sock"

input=$(cat)

payload=$(python3 -c "
import json, sys, os

try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

session_id = d.get('session_id', '')
cwd        = d.get('cwd', '')
source     = d.get('source', 'startup')

if not session_id:
    sys.exit(0)

# Detect account from CLAUDE_CONFIG_DIR
account = ''
try:
    config_dir = os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude')
    config_dir = os.path.realpath(os.path.expanduser(config_dir))
    accounts_path = os.path.expanduser('~/.claude/accounts.json')
    accounts_data = json.load(open(accounts_path))
    for name, info in accounts_data.get('accounts', {}).items():
        registered = os.path.realpath(os.path.expanduser(info.get('config_dir', '')))
        if registered == config_dir:
            account = name
            break
except Exception:
    pass

print(json.dumps({
    'type':       'session_register',
    'session_id': session_id,
    'cwd':        cwd,
    'source':     source,
    'account':    account,
}))
" "$input" 2>/dev/null)

[ -n "\$payload" ] && [ -S "\$SOCK" ] && printf '%s' "\$payload" | nc -U -w 2 "\$SOCK"

exit 0
```

Note: `$input` and `$SOCK` are shell vars — the python3 block is a single-quoted heredoc
argument, so `$input` and `$SOCK` in the last two lines remain as shell interpolation.
The file above shows the complete replacement for the entire script.

---

## 3. `ClaudeNotifier.swift` — Changes

The Swift file is at `.claude/tools/ClaudeNotifier.swift` (~895 lines).
Read the full file before editing. Changes are additive — nothing existing is removed.

### 3a. Add `AccountConfig` struct and `accountConfigs` property

**After** the `var sessions: [String: Session] = [:]` line, add:

```swift
struct AccountConfig {
    var displayName: String
    var color: NSColor
}
var accountConfigs: [String: AccountConfig] = [:]
```

### 3b. Add `account: String?` to `Session` struct

The `Session` struct currently has these fields:
```swift
struct Session {
    var id: String
    var cwd: String
    var displayName: String
    var isWorking: Bool
    var currentTool: String?
    var currentCommand: String?
    var toolUpdatedAt: Date?
    var isDone: Bool
    var doneAt: Date?
}
```

Add `var account: String?` after `var id: String`.

### 3c. Add `account: String?` to `PanelContentView.Row`

The `Row` struct in `PanelContentView` currently has:
```swift
struct Row {
    var cwd: String
    var displayName: String
    var isWorking: Bool
    var currentTool: String?
    var currentCommand: String?
    var isDone: Bool
    var agents: [(id: String, name: String)]
}
```

Add `var account: String?` and `var accountColor: NSColor?` after `var isDone`.

### 3d. Add color mapping helper to `ClaudeNotifierDaemon`

Add this method anywhere in the `ClaudeNotifierDaemon` class (e.g. near `formatCost` if it
exists, or just before `loadAccountConfigs`):

```swift
func color(for name: String?) -> NSColor {
    switch name {
    case "blue":   return .systemBlue
    case "green":  return .systemGreen
    case "orange": return .systemOrange
    case "red":    return .systemRed
    case "purple": return .systemPurple
    case "yellow": return .systemYellow
    default:       return .secondaryLabelColor
    }
}
```

### 3e. Add `loadAccountConfigs()` method

```swift
func loadAccountConfigs() {
    let path = NSHomeDirectory() + "/.claude/accounts.json"
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accounts = json["accounts"] as? [String: Any]
    else {
        accountConfigs = [:]
        return
    }
    var configs: [String: AccountConfig] = [:]
    for (name, value) in accounts {
        guard let info = value as? [String: Any] else { continue }
        let displayName = info["display_name"] as? String ?? name
        let colorName   = info["color"] as? String
        configs[name] = AccountConfig(displayName: displayName, color: color(for: colorName))
    }
    accountConfigs = configs
}
```

### 3f. Call `loadAccountConfigs()` during init

In the `override init()` of `ClaudeNotifierDaemon`, after `super.init()`, add:
```swift
loadAccountConfigs()
```

### 3g. Add `handleAccountsChanged()` method

```swift
func handleAccountsChanged(_ json: [String: Any]) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] daemon: accounts_changed — reloading configs")
    loadAccountConfigs()
    updateStatusTitle()
    refresh()
}
```

### 3h. Add `accounts_changed` case to the switch in `handleClient`

In the `switch msgType { ... }` block, before `default: break`, add:
```swift
case "accounts_changed":
    DispatchQueue.main.async { [weak self] in self?.handleAccountsChanged(json) }
```

### 3i. Update `handleSessionRegister` to store account

Current code creates the `Session` with no account. Add account reading:

Find this in `handleSessionRegister`:
```swift
sessions[sessionId] = Session(
    id: sessionId, cwd: cwd, displayName: displayName, isWorking: false,
    currentTool: nil, currentCommand: nil, toolUpdatedAt: nil, isDone: false, doneAt: nil)
```

Replace with:
```swift
let account = json["account"] as? String
sessions[sessionId] = Session(
    id: sessionId, cwd: cwd, displayName: displayName, isWorking: false,
    currentTool: nil, currentCommand: nil, toolUpdatedAt: nil, isDone: false, doneAt: nil,
    account: account?.isEmpty == false ? account : nil)
```

### 3j. Update `refresh()` to pass account info to panel rows

In `refresh()`, the `rows` mapping currently is:
```swift
let rows = sessions.values.sorted { $0.displayName < $1.displayName }.map { s in
    PanelContentView.Row(
        cwd: s.cwd, displayName: s.displayName, isWorking: s.isWorking,
        currentTool: s.currentTool, currentCommand: s.currentCommand,
        isDone: s.isDone, agents: agentSessions[s.id]?.agents ?? [])
}
```

Replace with:
```swift
let rows = sessions.values.sorted { $0.displayName < $1.displayName }.map { s in
    let acctColor = s.account.flatMap { accountConfigs[$0]?.color }
    return PanelContentView.Row(
        cwd: s.cwd, displayName: s.displayName, isWorking: s.isWorking,
        currentTool: s.currentTool, currentCommand: s.currentCommand,
        isDone: s.isDone, agents: agentSessions[s.id]?.agents ?? [],
        account: s.account, accountColor: acctColor)
}
```

Also add `usageText: String? = nil` parameter to the `panelContent.refresh(...)` call
(pass `nil` for now — this is the future extension point for usage display):
```swift
panelContent.refresh(
    inputs: inputs, rows: rows,
    spinnerChar: spinnerFrames[spinnerFrame],
    usageText: nil,
    onFocus: { ... },
    onAnswer: { ... })
```

### 3k. Update `updateStatusTitle()` for account dots

Replace the entire `updateStatusTitle()` method with this version that uses
`attributedTitle` to render colored account dots for working sessions:

```swift
func updateStatusTitle() {
    // Priority 1: any pending input
    if !pendingInputs.isEmpty {
        statusItem.button?.title = "⁇ claudeship"
        statusItem.button?.attributedTitle = NSAttributedString(string: "⁇ claudeship")
        return
    }

    let total = sessions.count
    let workingSessions = sessions.values.filter { $0.isWorking }
    let working = workingSessions.count

    // Priority 2: any session working
    if working > 0 {
        let countStr = "\(working)/\(total)"
        let recentSession = workingSessions
            .filter { $0.currentTool != nil }
            .max(by: { ($0.toolUpdatedAt ?? .distantPast) < ($1.toolUpdatedAt ?? .distantPast) })

        // Build tool suffix string
        let toolSuffix: String
        if let tool = recentSession?.currentTool {
            let cmd = recentSession?.currentCommand.map { " \($0)" } ?? ""
            toolSuffix = " — \(tool):\(cmd)"
        } else {
            toolSuffix = ""
        }

        // Collect unique account colors from working sessions (preserve insertion order)
        var seenAccounts: [String] = []
        var dotColors: [NSColor] = []
        for s in workingSessions {
            let key = s.account ?? "__none__"
            if !seenAccounts.contains(key) {
                seenAccounts.append(key)
                if let acct = s.account, let cfg = accountConfigs[acct] {
                    dotColors.append(cfg.color)
                }
            }
        }

        if dotColors.isEmpty {
            // No account info — plain string title
            let plain = "\(spinnerFrames[spinnerFrame]) \(countStr) claudeship\(toolSuffix)"
            statusItem.button?.title = plain
            statusItem.button?.attributedTitle = NSAttributedString(string: plain)
        } else {
            let attr = NSMutableAttributedString()
            let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
            attr.append(NSAttributedString(string: "\(spinnerFrames[spinnerFrame]) \(countStr) ", attributes: base))
            for dotColor in dotColors {
                attr.append(NSAttributedString(string: "●", attributes: [.foregroundColor: dotColor]))
            }
            attr.append(NSAttributedString(string: " claudeship\(toolSuffix)", attributes: base))
            statusItem.button?.attributedTitle = attr
        }
        return
    }

    // Priority 3: recently done
    if sessions.values.contains(where: { $0.isDone }) {
        let plain = "✓ claudeship"
        statusItem.button?.title = plain
        statusItem.button?.attributedTitle = NSAttributedString(string: plain)
        return
    }

    // Priority 4: idle
    let plain = total == 0 ? "✳ claudeship" : "✳ \(total) claudeship"
    statusItem.button?.title = plain
    statusItem.button?.attributedTitle = NSAttributedString(string: plain)
}
```

### 3l. Update `PanelContentView.refresh()` — add `usageText` param + account dots

**Signature change:** add two parameters:
```swift
func refresh(
    inputs: [InputRow],
    rows: [Row],
    spinnerChar: String = "⣷",
    usageText: String? = nil,          // ← new, extension point for usage display
    onFocus: @escaping (String) -> Void,
    onAnswer: @escaping (String, String) -> Void
)
```

**`addRow` overload:** Add a second overload that accepts `NSAttributedString` so session
rows can render colored account dots. Keep the existing `addRow(indent:text:color:cwd:onFocus:)`
untouched — it's used for done sessions and subagents which don't need colored dots.

Add this new overload:
```swift
private func addRow(
    indent: CGFloat, attrText: NSAttributedString,
    cwd: String, onFocus: @escaping (String) -> Void
) {
    let row = ClickableRow()
    row.translatesAutoresizingMaskIntoConstraints = false
    if !cwd.isEmpty { row.clickAction = { onFocus(cwd) } }

    let lbl = NSTextField(labelWithString: "")
    lbl.attributedStringValue = attrText
    lbl.lineBreakMode = .byTruncatingTail
    lbl.translatesAutoresizingMaskIntoConstraints = false
    row.addSubview(lbl)

    NSLayoutConstraint.activate([
        row.heightAnchor.constraint(equalToConstant: 22),
        lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: indent),
        lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        lbl.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
    ])

    stack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}
```

**Section C — active sessions:** Replace the `for row in activeSessions` block with a
version that builds `NSAttributedString` when `row.accountColor` is non-nil:

```swift
for row in activeSessions {
    // Build activity prefix + tool suffix as plain strings
    let prefix: String
    if row.isWorking {
        if let tool = row.currentTool {
            let cmd = row.currentCommand.map { " \($0)" } ?? ""
            prefix = "\(spinnerChar)  \(row.displayName)"
            let suffix = "  —  \(tool):\(cmd)"
            // Build attributed string
            buildSessionRow(row: row, prefix: prefix, suffix: suffix, cwd: row.cwd, onFocus: onFocus)
        } else {
            let prefix2 = "\(spinnerChar)  \(row.displayName)"
            buildSessionRow(row: row, prefix: prefix2, suffix: "  —  working", cwd: row.cwd, onFocus: onFocus)
        }
    } else {
        buildSessionRow(row: row, prefix: "○  \(row.displayName)", suffix: "  —  idle", cwd: row.cwd, onFocus: onFocus)
    }
    for agent in row.agents {
        addRow(
            indent: 16,
            text: "↳  \(agent.name.isEmpty ? "subagent" : agent.name)",
            color: .labelColor,
            cwd: row.cwd,
            onFocus: onFocus
        )
    }
}
```

Add the `buildSessionRow` helper inside `PanelContentView`:
```swift
private func buildSessionRow(
    row: Row, prefix: String, suffix: String,
    cwd: String, onFocus: @escaping (String) -> Void
) {
    if let accountColor = row.accountColor {
        let attr = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13)
        ]
        attr.append(NSAttributedString(string: prefix, attributes: base))
        attr.append(NSAttributedString(string: " ●", attributes: [
            .foregroundColor: accountColor,
            .font: NSFont.systemFont(ofSize: 13)
        ]))
        attr.append(NSAttributedString(string: suffix, attributes: base))
        addRow(indent: 0, attrText: attr, cwd: cwd, onFocus: onFocus)
    } else {
        addRow(indent: 0, text: prefix + suffix, color: .labelColor, cwd: cwd, onFocus: onFocus)
    }
}
```

**Section D — usage footer (baked in, not rendered yet):**
At the very end of `refresh()`, after Section C, add:
```swift
// ── Section D: Usage footer (future) ─────────────────────────────────────────
if let usageText = usageText {
    addSeparator()
    let lbl = NSTextField(labelWithString: usageText)
    lbl.textColor = .secondaryLabelColor
    lbl.font = .systemFont(ofSize: 11)
    lbl.translatesAutoresizingMaskIntoConstraints = false
    let usageRow = NSView()
    usageRow.translatesAutoresizingMaskIntoConstraints = false
    usageRow.addSubview(lbl)
    NSLayoutConstraint.activate([
        usageRow.heightAnchor.constraint(equalToConstant: 18),
        lbl.leadingAnchor.constraint(equalTo: usageRow.leadingAnchor),
        lbl.centerYAnchor.constraint(equalTo: usageRow.centerYAnchor),
        lbl.trailingAnchor.constraint(lessThanOrEqualTo: usageRow.trailingAnchor),
    ])
    stack.addArrangedSubview(usageRow)
    usageRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}
```

---

## 4. Example file: `.claude/docs/accounts.example.json`

Create this in the repo as a reference:
```json
{
  "accounts": {
    "personal": {
      "display_name": "Personal",
      "config_dir": "~/.claude",
      "color": "blue"
    },
    "work": {
      "display_name": "Work",
      "config_dir": "~/.claude-work",
      "color": "green"
    }
  }
}
```

---

## Build Order Within Track B

1. `accounts.example.json` (reference file, no deps)
2. `accounts.py` (no ClaudeNotifier deps)
3. `notify-session-register.sh` (replace existing, no ClaudeNotifier deps)
4. `ClaudeNotifier.swift` (all additions, rebuild after)

After Swift changes, rebuild with the standard process documented in CLAUDE.md:
```bash
cd /Users/joshuasegal/Coding/claudeship
swiftc .claude/tools/ClaudeNotifier.swift -o .claude/tools/ClaudeNotifier -framework Cocoa
cp .claude/tools/ClaudeNotifier /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
codesign --force --sign - /Applications/ClaudeNotifier.app/Contents/MacOS/ClaudeNotifier
launchctl unload ~/Library/LaunchAgents/com.claudeship.notifier.plist
launchctl load ~/Library/LaunchAgents/com.claudeship.notifier.plist
```
(Editing ClaudeNotifier.swift via Claude auto-triggers this per CLAUDE.md PostToolUse hook)

---

## Testing

```bash
# List accounts (will show unknown if accounts.json doesn't exist)
python3 ~/.claude/tools/accounts.py list

# Add an account
python3 ~/.claude/tools/accounts.py add work \
  --config-dir ~/.claude-work \
  --color green \
  --display-name "Work"

# Check current
python3 ~/.claude/tools/accounts.py current

# Verify accounts.json was written
cat ~/.claude/accounts.json

# Verify daemon received accounts_changed (check log)
tail -5 /tmp/claude-notifier.log

# Open a new Claude session with work account and verify dot in panel
CLAUDE_CONFIG_DIR=~/.claude-work claude
# → open panel (Cmd+Shift+C), session row should show green ●
```
