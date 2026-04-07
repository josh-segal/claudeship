import os
import subprocess

import pytest


GIT_ENV = {
    "GIT_AUTHOR_NAME": "test",
    "GIT_AUTHOR_EMAIL": "test@local",
    "GIT_COMMITTER_NAME": "test",
    "GIT_COMMITTER_EMAIL": "test@local",
    "HOME": "/tmp",
    "PATH": os.environ.get("PATH", ""),
}


@pytest.fixture
def config_dir(tmp_path, monkeypatch):
    """Set up a fake config dir with an initialized backup git repo."""
    import backup

    d = tmp_path / "claude-config"
    d.mkdir()
    monkeypatch.setattr(backup, "CONFIG_DIR", str(d))

    # Write some initial config files
    (d / "settings.json").write_text('{"theme": "dark"}')
    (d / "accounts.json").write_text('{"accounts": {}}')
    (d / ".gitignore").write_text("state.json\n")

    # Init git repo
    subprocess.run(["git", "init", "-q"], cwd=str(d), env=GIT_ENV, check=True)
    subprocess.run(["git", "add", "-A"], cwd=str(d), env=GIT_ENV, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "Initial backup"],
        cwd=str(d),
        env=GIT_ENV,
        check=True,
    )

    return d


# ── preflight ────────────────────────────────────────────────────────────────


def test_preflight_passes_with_git_repo(config_dir):
    from backup import preflight

    assert preflight() is True


def test_preflight_fails_without_git_dir(tmp_path, monkeypatch):
    import backup

    d = tmp_path / "no-git"
    d.mkdir()
    monkeypatch.setattr(backup, "CONFIG_DIR", str(d))
    assert backup.preflight() is False


# ── get_log ──────────────────────────────────────────────────────────────────


def test_get_log_returns_initial_commit(config_dir):
    from backup import get_log

    entries = get_log()
    assert len(entries) == 1
    assert entries[0]["message"] == "Initial backup"
    assert "hash" in entries[0]
    assert "ago" in entries[0]


def test_get_log_returns_multiple_commits(config_dir):
    from backup import get_log

    # Create a second commit
    (config_dir / "settings.json").write_text('{"theme": "light"}')
    subprocess.run(["git", "add", "-A"], cwd=str(config_dir), env=GIT_ENV, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "Changed theme"],
        cwd=str(config_dir),
        env=GIT_ENV,
        check=True,
    )

    entries = get_log()
    assert len(entries) == 2
    assert entries[0]["message"] == "Changed theme"
    assert entries[1]["message"] == "Initial backup"


# ── resolve_nth ──────────────────────────────────────────────────────────────


def test_resolve_nth_valid(config_dir):
    from backup import resolve_nth

    entry = resolve_nth(1)
    assert entry is not None
    assert entry["message"] == "Initial backup"


def test_resolve_nth_out_of_range(config_dir):
    from backup import resolve_nth

    assert resolve_nth(0) is None
    assert resolve_nth(99) is None


# ── cmd_list ─────────────────────────────────────────────────────────────────


def test_cmd_list_prints_entries(config_dir, capsys):
    from backup import cmd_list

    cmd_list()
    out = capsys.readouterr().out
    assert "Initial backup" in out
    assert "#" in out


# ── cmd_diff ─────────────────────────────────────────────────────────────────


def test_cmd_diff_shows_initial_commit(config_dir, capsys):
    from backup import cmd_diff

    cmd_diff(1)
    out = capsys.readouterr().out
    assert "Backup #1" in out
    assert "Initial backup" in out


def test_cmd_diff_shows_changes(config_dir, capsys):
    from backup import cmd_diff

    (config_dir / "settings.json").write_text('{"theme": "light"}')
    subprocess.run(["git", "add", "-A"], cwd=str(config_dir), env=GIT_ENV, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "Changed theme"],
        cwd=str(config_dir),
        env=GIT_ENV,
        check=True,
    )

    cmd_diff(1)
    out = capsys.readouterr().out
    assert "light" in out


# ── cmd_file ─────────────────────────────────────────────────────────────────


def test_cmd_file_restores(config_dir, capsys):
    from backup import cmd_file

    # Modify and commit so we have a backup of the original
    (config_dir / "settings.json").write_text('{"theme": "light"}')
    subprocess.run(["git", "add", "-A"], cwd=str(config_dir), env=GIT_ENV, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "Changed theme"],
        cwd=str(config_dir),
        env=GIT_ENV,
        check=True,
    )

    # Modify again (uncommitted)
    (config_dir / "settings.json").write_text('{"theme": "blue"}')

    # Restore to last committed version
    cmd_file("settings.json")
    restored = (config_dir / "settings.json").read_text()
    assert restored == '{"theme": "light"}'

    out = capsys.readouterr().out
    assert "Restored" in out


def test_cmd_file_nonexistent(config_dir, capsys):
    from backup import cmd_file

    cmd_file("nonexistent.json")
    out = capsys.readouterr().out
    assert "No backup found" in out


# ── cmd_all ──────────────────────────────────────────────────────────────────


def test_cmd_all_restores_to_snapshot(config_dir, capsys):
    from backup import cmd_all

    # Modify and commit
    (config_dir / "settings.json").write_text('{"theme": "light"}')
    subprocess.run(["git", "add", "-A"], cwd=str(config_dir), env=GIT_ENV, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "Changed theme"],
        cwd=str(config_dir),
        env=GIT_ENV,
        check=True,
    )

    # Restore to initial backup (#2 since "Changed theme" is #1)
    cmd_all(2)
    restored = (config_dir / "settings.json").read_text()
    assert restored == '{"theme": "dark"}'

    out = capsys.readouterr().out
    assert "Restored to backup #2" in out
    assert "reversible" in out


def test_cmd_all_creates_new_commit(config_dir):
    from backup import cmd_all, get_log

    (config_dir / "settings.json").write_text('{"theme": "light"}')
    subprocess.run(["git", "add", "-A"], cwd=str(config_dir), env=GIT_ENV, check=True)
    subprocess.run(
        ["git", "commit", "-q", "-m", "Changed theme"],
        cwd=str(config_dir),
        env=GIT_ENV,
        check=True,
    )

    cmd_all(2)
    entries = get_log()
    # Should have 3 commits: initial, change, restore
    assert len(entries) == 3
    assert "Restored" in entries[0]["message"]
