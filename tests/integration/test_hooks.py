"""
Integration tests for Claude Code hook scripts.

These tests run the actual bash scripts via subprocess, feeding them JSON
on stdin and capturing what they send to a mock Unix domain socket.
"""

import json
import os
import subprocess
import tempfile
import time

import pytest

HOOKS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", ".claude", "hooks")
SESSION_REGISTER_HOOK = os.path.join(
    HOOKS_DIR, "notifications", "notify-session-register.sh"
)
PERMISSION_HOOK = os.path.join(HOOKS_DIR, "notifications", "notify-permission.sh")
INPUT_HOOK = os.path.join(HOOKS_DIR, "notifications", "notify-input.sh")

pytestmark = pytest.mark.integration


def run_patched_hook(
    hook_path,
    stdin_data: dict,
    sock_path: str,
    patches: list = None,
    env: dict = None,
    timeout: int = 10,
) -> subprocess.CompletedProcess:
    """
    Run a hook with the SOCK path replaced and any additional text patches applied.
    patches is a list of (old_str, new_str) tuples applied after the SOCK substitution.
    """
    with open(hook_path) as f:
        content = f.read()

    patched = content.replace('SOCK="/tmp/claude-notifier.sock"', f'SOCK="{sock_path}"')
    for old, new in patches or []:
        patched = patched.replace(old, new)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
        f.write(patched)
        tmp = f.name
    os.chmod(tmp, 0o755)

    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    try:
        result = subprocess.run(
            ["bash", tmp],
            input=json.dumps(stdin_data),
            capture_output=True,
            text=True,
            env=full_env,
            timeout=timeout,
        )
    finally:
        os.unlink(tmp)

    return result


def run_hook(
    hook_path, stdin_data: dict, env: dict = None, sock_path: str = None
) -> subprocess.CompletedProcess:
    """Run a hook script, feeding stdin_data as JSON. Optionally override SOCK."""
    full_env = os.environ.copy()
    if env:
        full_env.update(env)
    if sock_path:
        # Patch the SOCK variable the hook uses by prepending an override
        full_env["_SOCK_OVERRIDE"] = sock_path

    return subprocess.run(
        ["bash", hook_path],
        input=json.dumps(stdin_data),
        capture_output=True,
        text=True,
        env=full_env,
        timeout=5,
    )


def run_hook_with_sock(
    hook_path, stdin_data: dict, sock_path: str, env: dict = None
) -> subprocess.CompletedProcess:
    """
    Run a hook with a patched SOCK path.
    We use `sed` inline substitution via a wrapper to redirect the socket path.
    Simpler: just run via `env SOCK=... bash -c "source hook && ..."` isn't clean.
    Instead, we create a temp wrapper that overrides SOCK before sourcing.
    """
    import tempfile

    wrapper = f"""#!/bin/bash
SOCK="{sock_path}"
{open(hook_path).read().split("SOCK=")[1].split("\n", 1)[1] if "SOCK=" in open(hook_path).read() else ""}
"""
    # Cleaner approach: just sed the SOCK line
    hook_content = open(hook_path).read()
    patched = hook_content.replace(
        'SOCK="/tmp/claude-notifier.sock"', f'SOCK="{sock_path}"'
    )

    with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
        f.write(patched)
        tmp_path = f.name

    os.chmod(tmp_path, 0o755)
    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    try:
        result = subprocess.run(
            ["bash", tmp_path],
            input=json.dumps(stdin_data),
            capture_output=True,
            text=True,
            env=full_env,
            timeout=5,
        )
    finally:
        os.unlink(tmp_path)

    return result


# ── notify-session-register.sh ────────────────────────────────────────────────


class TestSessionRegisterHook:
    def test_payload_structure(self, mock_socket):
        """Valid input produces a well-formed session_register payload."""
        sock_path, received = mock_socket
        run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {"session_id": "abc123", "cwd": "/tmp/myproject", "source": "startup"},
            sock_path,
        )
        time.sleep(0.5)  # allow socket thread to receive

        assert len(received) == 1
        payload = received[0]
        assert payload["type"] == "session_register"
        assert payload["session_id"] == "abc123"
        assert payload["cwd"] == "/tmp/myproject"
        assert payload["source"] == "startup"
        assert "account" in payload  # key always present

    def test_account_detected_from_env(self, mock_socket, tmp_path):
        """When CLAUDE_CONFIG_DIR matches an account, account name is included."""
        sock_path, received = mock_socket

        # Set up accounts.json pointing at tmp_path
        accounts_path = tmp_path / "accounts.json"
        config_dir = tmp_path / "work-config"
        config_dir.mkdir()
        accounts_path.write_text(
            json.dumps(
                {
                    "accounts": {
                        "work": {
                            "display_name": "Work",
                            "config_dir": str(config_dir),
                            "color": "green",
                        }
                    }
                }
            )
        )

        # Patch HOME so os.path.expanduser("~/.claude/accounts.json") hits our file
        fake_home = tmp_path
        (fake_home / ".claude").mkdir(exist_ok=True)
        os.rename(str(accounts_path), str(fake_home / ".claude" / "accounts.json"))

        run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {"session_id": "sess1", "cwd": "/tmp/proj", "source": "startup"},
            sock_path,
            env={
                "CLAUDE_CONFIG_DIR": str(config_dir),
                "HOME": str(fake_home),
            },
        )
        time.sleep(0.5)

        assert len(received) == 1
        assert received[0]["account"] == "work"

    def test_no_accounts_json_sends_empty_account(self, mock_socket, tmp_path):
        """Missing accounts.json → account field is empty string, not an error."""
        sock_path, received = mock_socket

        run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {"session_id": "sess2", "cwd": "/tmp/proj", "source": "startup"},
            sock_path,
            env={"HOME": str(tmp_path)},  # no .claude/accounts.json here
        )
        time.sleep(0.5)

        assert len(received) == 1
        assert received[0]["account"] == ""

    def test_missing_session_id_sends_nothing(self, mock_socket):
        """Hook must send nothing if session_id is absent."""
        sock_path, received = mock_socket
        run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {"cwd": "/tmp/proj", "source": "startup"},  # no session_id
            sock_path,
        )
        time.sleep(0.5)
        assert len(received) == 0

    def test_empty_session_id_sends_nothing(self, mock_socket):
        """Hook must send nothing if session_id is empty string."""
        sock_path, received = mock_socket
        run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {"session_id": "", "cwd": "/tmp/proj"},
            sock_path,
        )
        time.sleep(0.5)
        assert len(received) == 0

    def test_invalid_json_input_sends_nothing(self, mock_socket):
        """Malformed stdin → hook exits cleanly without sending."""
        sock_path, received = mock_socket
        import tempfile

        hook_content = (
            open(SESSION_REGISTER_HOOK)
            .read()
            .replace('SOCK="/tmp/claude-notifier.sock"', f'SOCK="{sock_path}"')
        )
        with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as f:
            f.write(hook_content)
            tmp = f.name
        os.chmod(tmp, 0o755)

        try:
            subprocess.run(
                ["bash", tmp],
                input="not valid json",
                capture_output=True,
                text=True,
                timeout=5,
            )
        finally:
            os.unlink(tmp)

        time.sleep(0.5)
        assert len(received) == 0

    def test_broken_accounts_json_sends_empty_account(self, mock_socket, tmp_path):
        """Corrupt accounts.json must fall through to empty account, not crash the hook."""
        sock_path, received = mock_socket

        fake_home = tmp_path
        (fake_home / ".claude").mkdir()
        (fake_home / ".claude" / "accounts.json").write_text("{ broken json {{")

        run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {"session_id": "sess-broken", "cwd": "/tmp/proj", "source": "startup"},
            sock_path,
            env={"HOME": str(fake_home)},
        )
        time.sleep(0.5)

        assert len(received) == 1
        assert received[0]["account"] == ""

    def test_hook_exits_zero(self):
        """Hook must always exit 0 regardless of input."""
        result = run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {"session_id": "x", "cwd": "/tmp"},
            "/tmp/nonexistent-test.sock",  # socket doesn't exist — hook should still exit 0
        )
        assert result.returncode == 0

    def test_hook_exits_zero_on_empty_input(self):
        result = run_hook_with_sock(
            SESSION_REGISTER_HOOK,
            {},
            "/tmp/nonexistent-test.sock",
        )
        assert result.returncode == 0


# ── notify-permission.sh clearing ────────────────────────────────────────────


class TestPermissionHookClearing:
    """
    Bug: when notify-permission.sh times out (user answered in TUI instead of
    clicking the panel), it exits 0 without sending session_inputs_clear.
    The daemon's pendingInputs entry is never removed, so ⚡ persists until
    the next tool fires.
    """

    def test_timeout_sends_session_inputs_clear(self, multi_message_socket):
        """
        FAILING: timeout path must send session_inputs_clear so the daemon
        removes the stale pending input immediately.

        Patch read timeout to 1s so the test doesn't take 30s.
        """
        sock_path, received = multi_message_socket
        session_id = "test-session-perm-timeout"

        run_patched_hook(
            PERMISSION_HOOK,
            {
                "session_id": session_id,
                "tool_name": "Write",
                "tool_input": {"file_path": "/tmp/test.py"},
                "permission_suggestions": [],
            },
            sock_path,
            patches=[("read -r -t 30", "read -r -t 1")],
            timeout=5,
        )
        time.sleep(0.2)

        types = [m["type"] for m in received]
        assert "session_inputs_clear" in types, (
            "timeout path must send session_inputs_clear — "
            "without it ⚡ persists after TUI answer"
        )
        clear = next(m for m in received if m["type"] == "session_inputs_clear")
        assert clear["session_id"] == session_id

    def test_panel_answer_still_sends_inputs_clear(self, multi_message_socket):
        """
        Sanity check: the happy path (panel button clicked) must also result in
        session_inputs_clear being received. This passes today via the explicit
        send inside the `if read` branch.
        """
        sock_path, received = multi_message_socket
        session_id = "test-session-perm-happy"

        # Run the hook and immediately write the chosen answer to the FIFO so
        # the read succeeds before the timeout.
        import threading

        hook_pid_holder = []

        def write_fifo_reply():
            # Give the hook time to create the FIFO and start blocking
            time.sleep(0.3)
            import glob as _glob

            fifos = _glob.glob("/tmp/claude-fifo-*")
            for fifo in fifos:
                try:
                    with open(fifo, "w") as f:
                        f.write("Yes\n")
                    break
                except OSError:
                    pass

        t = threading.Thread(target=write_fifo_reply, daemon=True)
        t.start()

        run_patched_hook(
            PERMISSION_HOOK,
            {
                "session_id": session_id,
                "tool_name": "Write",
                "tool_input": {"file_path": "/tmp/test.py"},
                "permission_suggestions": [],
            },
            sock_path,
            patches=[("read -r -t 30", "read -r -t 5")],
            timeout=6,
        )
        t.join(timeout=2)
        time.sleep(0.2)

        types = [m["type"] for m in received]
        assert "session_inputs_clear" in types
        clear = next(m for m in received if m["type"] == "session_inputs_clear")
        assert clear["session_id"] == session_id


# ── notify-input.sh clearing ──────────────────────────────────────────────────


class TestInputHookClearing:
    """
    Bug: when notify-input.sh times out (user answered AskUserQuestion in TUI),
    it exits 0 without sending session_inputs_clear. Same stale ⚡ problem.
    """

    def test_timeout_sends_session_inputs_clear(self, multi_message_socket):
        """
        FAILING: timeout path must send session_inputs_clear.

        Patch `seq 1 600` → `seq 1 2` so the poll loop runs for ~2s instead of
        10 minutes.
        """
        sock_path, received = multi_message_socket
        session_id = "test-session-input-timeout"

        run_patched_hook(
            INPUT_HOOK,
            {
                "session_id": session_id,
                "input": {
                    "questions": [
                        {
                            "question": "Which format?",
                            "options": [{"label": "JSON"}, {"label": "YAML"}],
                        }
                    ]
                },
            },
            sock_path,
            patches=[("seq 1 600", "seq 1 2")],
            env={"CLAUDE_SESSION_ID": session_id},
            timeout=8,
        )
        time.sleep(0.2)

        types = [m["type"] for m in received]
        assert "session_inputs_clear" in types, (
            "timeout path must send session_inputs_clear — "
            "without it ⚡ persists after TUI answer"
        )
        clear = next(m for m in received if m["type"] == "session_inputs_clear")
        assert clear["session_id"] == session_id
