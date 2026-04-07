#!/usr/bin/env python3
"""
backup.py — Git-based backup manager for Claude config dir.

Commands:
  list              Show recent backups with relative timestamps
  diff [N]          Show what changed at backup N
  file <path>       Restore a specific file from last backup
  all <N>           Restore everything to backup N
"""

import os
import shutil
import subprocess
import sys

CONFIG_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")

GIT_ENV = {
    **os.environ,
    "GIT_AUTHOR_NAME": "claude-backup",
    "GIT_AUTHOR_EMAIL": "backup@local",
    "GIT_COMMITTER_NAME": "claude-backup",
    "GIT_COMMITTER_EMAIL": "backup@local",
}


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=CONFIG_DIR,
        capture_output=True,
        text=True,
        check=check,
        env=GIT_ENV,
    )


def preflight() -> bool:
    if not shutil.which("git"):
        print("Error: git is not installed.")
        return False
    if not os.path.isdir(os.path.join(CONFIG_DIR, ".git")):
        print(
            "No backups found. Backups are initialized automatically at session start."
        )
        return False
    return True


def get_log(count: int = 20) -> list[dict]:
    result = git("log", "--format=%H|%ar|%s", f"-{count}", check=False)
    if result.returncode != 0 or not result.stdout.strip():
        return []
    entries = []
    for line in result.stdout.strip().splitlines():
        parts = line.split("|", 2)
        if len(parts) == 3:
            entries.append({"hash": parts[0], "ago": parts[1], "message": parts[2]})
    return entries


def resolve_nth(n: int) -> dict | None:
    entries = get_log(n)
    if n < 1 or n > len(entries):
        print(f"Error: backup #{n} not found. Use 'list' to see available backups.")
        return None
    return entries[n - 1]


# ─── Commands ───────────────────────────────────────────────────────────


def cmd_list():
    entries = get_log()
    if not entries:
        print("No backups found.")
        return
    print(f"Config dir: {CONFIG_DIR}")
    print()
    print("  #   When                 Description")
    print("  " + "─" * 55)
    for i, e in enumerate(entries, 1):
        print(f"  {i:<4}{e['ago']:<21}{e['message']}")


def cmd_diff(n: int = 1):
    entry = resolve_nth(n)
    if not entry:
        return

    sha = entry["hash"]
    # Check if this is the initial commit (no parent)
    parent = git("rev-parse", f"{sha}^", check=False)
    if parent.returncode != 0:
        # Initial commit — diff against empty tree
        result = git(
            "diff", "4b825dc642cb6eb9a060e54bf899d69f82cf7565", sha, check=False
        )
    else:
        result = git("diff", f"{sha}^", sha, check=False)

    print(f"Backup #{n}: {entry['message']} ({entry['ago']})")
    print()
    if result.stdout.strip():
        print(result.stdout)
    else:
        print("No file changes in this backup.")


def cmd_file(path: str):
    # Resolve relative to config dir
    if os.path.isabs(path):
        real_path = os.path.realpath(path)
        real_config = os.path.realpath(CONFIG_DIR)
        if not real_path.startswith(real_config + "/"):
            print(f"Error: {path} is not inside {CONFIG_DIR}")
            return
        relpath = os.path.relpath(real_path, real_config)
    else:
        relpath = path

    # Find last commit that touched this file
    result = git("log", "-1", "--format=%H|%ar|%s", "--", relpath, check=False)
    if result.returncode != 0 or not result.stdout.strip():
        print(f"No backup found for: {relpath}")
        return

    parts = result.stdout.strip().split("|", 2)
    sha, ago, msg = parts[0], parts[1], parts[2]

    git("checkout", sha, "--", relpath)
    print(f"Restored {relpath} from backup ({ago}): {msg}")


def cmd_all(n: int):
    entry = resolve_nth(n)
    if not entry:
        return

    sha = entry["hash"]
    git("checkout", sha, "--", ".")
    git("add", "-A")
    git("commit", "-m", f"Restored to backup #{n}: {entry['message']}", check=False)
    print(f"Restored to backup #{n}: {entry['message']} ({entry['ago']})")
    print("A new backup was created so this restore is reversible.")


# ─── CLI ────────────────────────────────────────────────────────────────


def main():
    if not preflight():
        sys.exit(1)

    args = sys.argv[1:]
    cmd = args[0] if args else "list"

    if cmd == "list":
        cmd_list()
    elif cmd == "diff":
        n = int(args[1]) if len(args) > 1 else 1
        cmd_diff(n)
    elif cmd == "file":
        if len(args) < 2:
            print("Usage: backup.py file <path>")
            sys.exit(1)
        cmd_file(args[1])
    elif cmd == "all":
        if len(args) < 2:
            print("Usage: backup.py all <N>")
            sys.exit(1)
        cmd_all(int(args[1]))
    else:
        print(f"Unknown command: {cmd}")
        print("Commands: list, diff [N], file <path>, all <N>")
        sys.exit(1)


if __name__ == "__main__":
    main()
