# Track A — Usage Implementation Plan

## Goal
Standalone usage tracking CLI. No UI integration yet. Clean extension point for later.

## Files to Create
- `~/.claude/tools/state.py` — shared atomic JSON R/W utility
- `~/.claude/tools/usage.py` — usage CLI
- Edit `CLAUDE.md` — add `/usage` command

No changes to ClaudeNotifier, hooks, or MCP.

---

## 1. `~/.claude/tools/state.py`

Shared utility imported by all claudeship scripts. Every tool that reads/writes
`~/.claude/state.json` uses this — never hand-rolls JSON operations.

### Interface
```python
STATE_PATH = os.path.expanduser("~/.claude/state.json")

def read_state() -> dict:
    """Read ~/.claude/state.json. Returns {} if missing or corrupt."""

def write_state(updates: dict) -> None:
    """Deep-merge updates into state, write atomically."""
```

### Implementation details
- **File locking:** use `fcntl.flock(fd, fcntl.LOCK_EX)` before read AND write
- **Atomic write:** write to `STATE_PATH + ".tmp"`, then `os.replace()` — never write directly
- **Deep merge:** `write_state` merges at top level (not shallow replace). Nested dicts are merged recursively. Leaf values overwrite.
- **Missing file:** `read_state()` returns `{}` if file doesn't exist, logs nothing
- **Corrupt JSON:** `read_state()` returns `{}` and prints warning to stderr
- **Lock timeout:** don't implement — `flock` will block until available, which is fine for CLI tools

### Initial state.json schema
When `write_state` creates the file for the first time (doesn't exist), it creates:
```json
{
  "active_workspace": null,
  "usage": {
    "daily":   { "cost": 0.0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0 },
    "weekly":  { "cost": 0.0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0 },
    "monthly": { "cost": 0.0, "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0 },
    "updated_at": null
  }
}
```
This schema is written on first `write_state` call by initializing with defaults before merging.

### Example
```python
from state import read_state, write_state

state = read_state()
account = state.get("active_workspace")  # None if not set

write_state({
    "usage": {
        "daily": {"cost": 0.45, "input_tokens": 12000, "output_tokens": 800, "cache_read_tokens": 4000}
    }
})
# Only "usage.daily" is updated — other keys untouched
```

---

## 2. `~/.claude/tools/usage.py`

### Behavior
- Reads all `~/.claude/projects/**/*.jsonl` files
- Parses entries that have a `costUSD` field (any positive float)
- Groups by: today (midnight UTC), this week (Monday midnight UTC), this month (1st midnight UTC)
- Writes results to `~/.claude/state.json` via `write_state`
- Prints output to stdout

### JSONL entry format
Each line in a `.jsonl` file is a JSON object. Relevant fields:
```json
{
  "type": "assistant",
  "costUSD": 0.015,
  "timestamp": "2026-04-01T10:23:45.123Z",
  "message": {
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 890
    }
  }
}
```
- Only entries with `costUSD > 0` are counted
- `timestamp` is ISO 8601 with Z suffix (and sometimes fractional seconds)
- `message.usage` may be absent — handle gracefully (treat as 0 tokens)
- `cache_read_tokens` maps to `message.usage.cache_read_input_tokens`

### Timestamp parsing
```python
from datetime import datetime, timezone, timedelta

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None
```

### Time bucket boundaries (all UTC)
```python
now = datetime.now(timezone.utc)
today_start  = now.replace(hour=0, minute=0, second=0, microsecond=0)
week_start   = today_start - timedelta(days=today_start.weekday())  # Monday
month_start  = today_start.replace(day=1)
```

### Output: `--json` flag
```json
{
  "daily":   { "cost": 0.45, "input_tokens": 12000, "output_tokens": 800,  "cache_read_tokens": 4000,  "total_tokens": 12800 },
  "weekly":  { "cost": 3.20, "input_tokens": 89000, "output_tokens": 6200, "cache_read_tokens": 31000, "total_tokens": 95200 },
  "monthly": { "cost": 12.5, "input_tokens": 310000,"output_tokens": 22000,"cache_read_tokens": 110000,"total_tokens": 332000 }
}
```
Round `cost` to 6 decimal places. `total_tokens = input_tokens + output_tokens` (not cache).

### Output: default human table
```
  Claude Code Usage
  ────────────────────────────────────────────
  Period    Cost       Input    Output     Cache
  ────────────────────────────────────────────
  Today    $  0.45    11.7k     0.8k       3.9k
  Week     $  3.20    87.0k     6.1k      30.3k
  Month    $ 12.50   303.0k    21.5k     107.4k
```
Token format helper: `1234 → "1.2k"`, `1234567 → "1.2M"`, `< 1000 → "123"`

### State.json write
After computing, always write regardless of `--json` flag:
```python
write_state({
    "usage": {
        "daily":   {"cost": ..., "input_tokens": ..., "output_tokens": ..., "cache_read_tokens": ...},
        "weekly":  {...},
        "monthly": {...},
        "updated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")
    }
})
```

### File structure
```
~/.claude/tools/usage.py
```
Import state.py with:
```python
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from state import write_state
```

### Error handling
- Missing `~/.claude/projects/` dir: print empty table (all zeros), still write state
- Unreadable JSONL file: skip silently
- Malformed JSON line: skip silently
- `--json` and default are the only flags; unrecognized args ignored

---

## 3. CLAUDE.md edit

Add this section to the end of `CLAUDE.md`:

```markdown
## Commands

### /usage
Run `python3 ~/.claude/tools/usage.py` and report the output. Shows daily, weekly,
and monthly Claude Code spend and token counts.
```

---

## Testing
After implementing, verify:
```bash
# Human table
python3 ~/.claude/tools/usage.py

# JSON output
python3 ~/.claude/tools/usage.py --json

# state.json was written
cat ~/.claude/state.json | python3 -m json.tool

# Import works
python3 -c "import sys; sys.path.insert(0, '$HOME/.claude/tools'); from state import read_state; print(read_state())"
```
