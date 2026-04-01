import os
import json
import fcntl
import sys
import tempfile

STATE_PATH = os.path.expanduser("~/.claude/state.json")

_DEFAULTS = {
    "active_workspace": None,
    "usage": {
        "daily": {
            "cost": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
        },
        "weekly": {
            "cost": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
        },
        "monthly": {
            "cost": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
        },
        "updated_at": None,
    },
}


def _deep_merge(base, updates):
    result = dict(base)
    for k, v in updates.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = _deep_merge(result[k], v)
        else:
            result[k] = v
    return result


def read_state() -> dict:
    """Read ~/.claude/state.json. Returns {} if missing or corrupt."""
    if not os.path.exists(STATE_PATH):
        return {}
    try:
        with open(STATE_PATH, "r") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                return json.load(f)
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
    except json.JSONDecodeError:
        print(
            f"warning: {STATE_PATH} is corrupt, returning empty state", file=sys.stderr
        )
        return {}


def write_state(updates: dict) -> None:
    """Deep-merge updates into state, write atomically."""
    current = read_state()
    if not current:
        current = _deep_merge({}, _DEFAULTS)
    merged = _deep_merge(current, updates)

    state_dir = os.path.dirname(STATE_PATH)
    os.makedirs(state_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=state_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                json.dump(merged, f, indent=2)
                f.write("\n")
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
        os.replace(tmp_path, STATE_PATH)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
