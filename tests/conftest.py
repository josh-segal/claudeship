import json
import os
import socket
import sys
import threading

import pytest

TOOLS_DIR = os.path.join(os.path.dirname(__file__), "..", ".claude", "tools")
HOOKS_DIR = os.path.join(os.path.dirname(__file__), "..", ".claude", "hooks")

# Ensure tools are importable in every test session
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)


# ── State isolation ───────────────────────────────────────────────────────────


@pytest.fixture
def state_file(tmp_path, monkeypatch):
    """Redirect state.STATE_PATH to a temp file for the duration of the test."""
    import state

    monkeypatch.setattr(state, "STATE_PATH", str(tmp_path / "state.json"))
    return tmp_path


# ── Accounts isolation ────────────────────────────────────────────────────────


@pytest.fixture
def accounts_dir(tmp_path, monkeypatch):
    """Redirect accounts.ACCOUNTS_PATH to a temp file for the duration of the test."""
    import accounts

    monkeypatch.setattr(accounts, "ACCOUNTS_PATH", str(tmp_path / "accounts.json"))
    return tmp_path


@pytest.fixture
def populated_accounts(accounts_dir, tmp_path):
    """Write a known accounts.json and return the accounts dict."""
    import accounts

    # Create fake config dirs so detect_current_account can realpath them
    personal_dir = tmp_path / "claude-personal"
    work_dir = tmp_path / "claude-work"
    personal_dir.mkdir()
    work_dir.mkdir()

    data = {
        "accounts": {
            "personal": {
                "display_name": "Personal",
                "config_dir": str(personal_dir),
                "color": "blue",
            },
            "work": {
                "display_name": "Work",
                "config_dir": str(work_dir),
                "color": "green",
            },
        }
    }
    with open(accounts.ACCOUNTS_PATH, "w") as f:
        json.dump(data, f)

    return {"personal": personal_dir, "work": work_dir}


# ── JSONL fixture helpers ─────────────────────────────────────────────────────


def make_entry(
    cost: float,
    timestamp: str,
    input_tokens: int = 100,
    output_tokens: int = 50,
    cache_read: int = 0,
) -> str:
    """Return a JSONL line with the given cost and timestamp."""
    return json.dumps(
        {
            "type": "assistant",
            "costUSD": cost,
            "timestamp": timestamp,
            "message": {
                "usage": {
                    "input_tokens": input_tokens,
                    "output_tokens": output_tokens,
                    "cache_read_input_tokens": cache_read,
                }
            },
        }
    )


# ── Mock Unix socket ──────────────────────────────────────────────────────────


@pytest.fixture
def mock_socket(tmp_path):
    """
    Spin up a temporary Unix domain socket server that collects one message.
    Yields (sock_path, received_list).
    The test sends to sock_path; after the hook runs, received_list[0] is the
    parsed JSON payload (or the list is empty if nothing arrived within 2s).

    Uses /tmp/ directly because AF_UNIX paths are limited to 108 chars on macOS
    and pytest's tmp_path can exceed that.
    """
    import uuid

    sock_path = f"/tmp/cs-test-{uuid.uuid4().hex[:8]}.sock"
    received = []

    def serve():
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sock_path)
        s.listen(1)
        s.settimeout(2.0)
        try:
            conn, _ = s.accept()
            data = b""
            while chunk := conn.recv(4096):
                data += chunk
            conn.close()
            if data:
                received.append(json.loads(data))
        except (socket.timeout, json.JSONDecodeError):
            pass
        finally:
            s.close()

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    yield sock_path, received
    t.join(timeout=3)
    if os.path.exists(sock_path):
        os.unlink(sock_path)
