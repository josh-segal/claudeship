#!/usr/bin/env python3
"""
accounts.py — Claude account registry CLI

Commands:
  list                                      Show all accounts, mark current
  add <name> --config-dir <path> --color <c> [--display-name <n>]
  remove <name>
  current                                   Detect from CLAUDE_CONFIG_DIR
"""

import json
import os
import sys
import socket as sock

sys.path.insert(0, os.path.dirname(__file__))

ACCOUNTS_PATH = os.path.expanduser("~/.claude/accounts.json")
VALID_COLORS = {"blue", "green", "orange", "red", "purple", "yellow"}


def load_accounts() -> dict:
    if not os.path.exists(ACCOUNTS_PATH):
        return {}
    try:
        with open(ACCOUNTS_PATH) as f:
            data = json.load(f)
        return data.get("accounts", {})
    except Exception:
        return {}


def save_accounts(accounts: dict):
    with open(ACCOUNTS_PATH, "w") as f:
        json.dump({"accounts": accounts}, f, indent=2)
        f.write("\n")


def detect_current_account(accounts: dict) -> str | None:
    """Match CLAUDE_CONFIG_DIR env var against accounts registry."""
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    config_dir = os.path.realpath(os.path.expanduser(config_dir))
    for name, info in accounts.items():
        registered = os.path.realpath(os.path.expanduser(info.get("config_dir", "")))
        if registered == config_dir:
            return name
    return None


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


def alias_for(name: str, config_dir: str) -> str:
    expanded = os.path.expanduser(config_dir)
    default = os.path.expanduser("~/.claude")
    if os.path.realpath(expanded) == os.path.realpath(default):
        return "claude"
    return f"claude-{name}"


def cmd_list():
    accounts = load_accounts()
    current = detect_current_account(accounts)

    print()
    print("  Accounts")
    print("  " + "─" * 45)

    if not accounts:
        print("  (no accounts registered)")
        print()
        return

    for name, info in accounts.items():
        dot = "●" if name == current else "○"
        display = info.get("display_name", name)
        config_dir = info.get("config_dir", "")
        alias = alias_for(name, config_dir)
        print(f"  {dot} {name:<12} {display:<12} {config_dir:<20} alias: {alias}")

    print()
    suggestions = []
    for name, info in accounts.items():
        config_dir = info.get("config_dir", "")
        alias = alias_for(name, config_dir)
        if alias != "claude":
            suggestions.append(
                f"    alias {alias}='CLAUDE_CONFIG_DIR={config_dir} claude'"
            )

    if suggestions:
        print("  Add to your shell profile:")
        for s in suggestions:
            print(s)
        print()


def cmd_add(args):
    import argparse

    parser = argparse.ArgumentParser(prog="accounts.py add")
    parser.add_argument("name")
    parser.add_argument("--config-dir", required=True)
    parser.add_argument("--color", required=True)
    parser.add_argument("--display-name", default=None)
    parsed = parser.parse_args(args)

    name = parsed.name
    config_dir = parsed.config_dir
    color = parsed.color
    display_name = parsed.display_name or name.capitalize()

    expanded = os.path.expanduser(config_dir)
    if not os.path.isdir(expanded):
        print(
            f"Error: config-dir '{config_dir}' does not exist or is not a directory",
            file=sys.stderr,
        )
        sys.exit(1)

    if color not in VALID_COLORS:
        print(
            f"Error: color '{color}' is not valid. Choose from: {', '.join(sorted(VALID_COLORS))}",
            file=sys.stderr,
        )
        sys.exit(1)

    accounts = load_accounts()
    accounts[name] = {
        "display_name": display_name,
        "config_dir": config_dir,
        "color": color,
    }
    save_accounts(accounts)

    alias = alias_for(name, config_dir)
    print(f"Added account '{name}' ({display_name})")
    if alias != "claude":
        print("\nAdd to your shell profile:")
        print(f"  alias {alias}='CLAUDE_CONFIG_DIR={config_dir} claude'")

    notify_daemon()


def cmd_remove(args):
    if not args:
        print("Error: missing account name", file=sys.stderr)
        sys.exit(1)
    name = args[0]

    accounts = load_accounts()
    if name not in accounts:
        print(f"Error: account '{name}' not found", file=sys.stderr)
        sys.exit(1)

    current = detect_current_account(accounts)
    if name == current:
        print(f"Warning: removing current account '{name}'")

    del accounts[name]
    save_accounts(accounts)
    print(f"Removed account '{name}'")
    notify_daemon()


def cmd_current():
    accounts = load_accounts()
    current = detect_current_account(accounts)
    print(current if current else "(unknown)")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    command = sys.argv[1]
    rest = sys.argv[2:]

    if command == "list":
        cmd_list()
    elif command == "add":
        cmd_add(rest)
    elif command == "remove":
        cmd_remove(rest)
    elif command == "current":
        cmd_current()
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
