import json
import os

import pytest


# ── detect_current_account ────────────────────────────────────────────────────


def test_detect_matches_claude_config_dir(populated_accounts, monkeypatch):
    from accounts import detect_current_account, load_accounts

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(populated_accounts["work"]))
    assert detect_current_account(load_accounts()) == "work"


def test_detect_unregistered_dir_returns_none(
    populated_accounts, monkeypatch, tmp_path
):
    from accounts import detect_current_account, load_accounts

    unknown = tmp_path / "unknown-config"
    unknown.mkdir()
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(unknown))
    assert detect_current_account(load_accounts()) is None


def test_detect_empty_registry_returns_none(accounts_dir, monkeypatch, tmp_path):
    from accounts import detect_current_account

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path))
    assert detect_current_account({}) is None


def test_detect_resolves_symlinks(populated_accounts, monkeypatch, tmp_path):
    """A symlink to the registered config_dir must still match the account."""
    from accounts import detect_current_account, load_accounts

    link = tmp_path / "work-link"
    os.symlink(str(populated_accounts["work"]), str(link))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(link))
    assert detect_current_account(load_accounts()) == "work"


# ── load_accounts ─────────────────────────────────────────────────────────────


def test_load_accounts_corrupt_file_returns_empty(accounts_dir):
    import accounts

    with open(accounts.ACCOUNTS_PATH, "w") as f:
        f.write("not json {{{")
    assert accounts.load_accounts() == {}


def test_load_accounts_returns_inner_accounts_dict(accounts_dir):
    import accounts

    data = {
        "accounts": {
            "personal": {
                "display_name": "Personal",
                "config_dir": "~/.claude",
                "color": "blue",
            }
        }
    }
    with open(accounts.ACCOUNTS_PATH, "w") as f:
        json.dump(data, f)
    result = accounts.load_accounts()
    assert "personal" in result
    assert result["personal"]["color"] == "blue"


def test_load_accounts_missing_config_dir_field(accounts_dir):
    """Entry missing config_dir must not crash detect_current_account."""
    import accounts

    with open(accounts.ACCOUNTS_PATH, "w") as f:
        json.dump(
            {"accounts": {"broken": {"display_name": "Broken", "color": "red"}}}, f
        )

    result = accounts.load_accounts()
    assert "broken" in result
    # detect_current_account falls back to "" for missing config_dir — should return None, not crash
    detected = accounts.detect_current_account(result)
    assert detected is None


# ── cmd_add ───────────────────────────────────────────────────────────────────


def test_cmd_add_writes_accounts_json(accounts_dir, tmp_path, monkeypatch):
    import accounts

    config_dir = tmp_path / "my-config"
    config_dir.mkdir()
    monkeypatch.setattr(accounts, "notify_daemon", lambda: None)

    accounts.cmd_add(["myaccount", "--config-dir", str(config_dir), "--color", "blue"])

    result = accounts.load_accounts()
    assert "myaccount" in result
    assert result["myaccount"]["color"] == "blue"
    assert result["myaccount"]["display_name"] == "Myaccount"


def test_cmd_add_custom_display_name(accounts_dir, tmp_path, monkeypatch):
    import accounts

    config_dir = tmp_path / "cfg"
    config_dir.mkdir()
    monkeypatch.setattr(accounts, "notify_daemon", lambda: None)

    accounts.cmd_add(
        [
            "work",
            "--config-dir",
            str(config_dir),
            "--color",
            "green",
            "--display-name",
            "Work Account",
        ]
    )
    assert accounts.load_accounts()["work"]["display_name"] == "Work Account"


def test_cmd_add_overwrites_existing_account(accounts_dir, tmp_path, monkeypatch):
    """Adding an account name that already exists silently overwrites it."""
    import accounts

    config_dir = tmp_path / "cfg"
    config_dir.mkdir()
    monkeypatch.setattr(accounts, "notify_daemon", lambda: None)

    accounts.cmd_add(["work", "--config-dir", str(config_dir), "--color", "green"])
    accounts.cmd_add(["work", "--config-dir", str(config_dir), "--color", "blue"])

    result = accounts.load_accounts()
    assert list(result.keys()).count("work") == 1  # no duplicate key
    assert result["work"]["color"] == "blue"  # last write wins


def test_cmd_add_invalid_config_dir_exits(accounts_dir, monkeypatch):
    import accounts

    monkeypatch.setattr(accounts, "notify_daemon", lambda: None)
    with pytest.raises(SystemExit) as exc:
        accounts.cmd_add(["x", "--config-dir", "/nonexistent/path", "--color", "blue"])
    assert exc.value.code == 1


def test_cmd_add_invalid_color_exits(accounts_dir, tmp_path, monkeypatch):
    import accounts

    config_dir = tmp_path / "cfg"
    config_dir.mkdir()
    monkeypatch.setattr(accounts, "notify_daemon", lambda: None)
    with pytest.raises(SystemExit) as exc:
        accounts.cmd_add(["x", "--config-dir", str(config_dir), "--color", "magenta"])
    assert exc.value.code == 1


# ── cmd_remove ────────────────────────────────────────────────────────────────


def test_cmd_remove_deletes_account(populated_accounts, monkeypatch):
    import accounts

    monkeypatch.setattr(accounts, "notify_daemon", lambda: None)
    monkeypatch.delenv("CLAUDE_CONFIG_DIR", raising=False)

    accounts.cmd_remove(["personal"])
    result = accounts.load_accounts()
    assert "personal" not in result
    assert "work" in result


def test_cmd_remove_nonexistent_exits(accounts_dir):
    import accounts

    with pytest.raises(SystemExit) as exc:
        accounts.cmd_remove(["ghost"])
    assert exc.value.code == 1


def test_cmd_remove_warns_on_current(populated_accounts, monkeypatch, capsys):
    import accounts

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(populated_accounts["work"]))
    monkeypatch.setattr(accounts, "notify_daemon", lambda: None)

    accounts.cmd_remove(["work"])
    assert "Warning" in capsys.readouterr().out


# ── cmd_current ───────────────────────────────────────────────────────────────


def test_cmd_current_known_account(populated_accounts, monkeypatch, capsys):
    import accounts

    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(populated_accounts["work"]))
    accounts.cmd_current()
    assert capsys.readouterr().out.strip() == "work"


def test_cmd_current_unknown_prints_unknown(
    accounts_dir, monkeypatch, tmp_path, capsys
):
    import accounts

    unknown = tmp_path / "unknown"
    unknown.mkdir()
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(unknown))
    accounts.cmd_current()
    assert "(unknown)" in capsys.readouterr().out
