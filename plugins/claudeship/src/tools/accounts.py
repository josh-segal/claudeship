#!/usr/bin/env python3
"""
accounts.py — Claude account registry CLI

Commands:
  list                                      Show all accounts, mark current
  add <name> --config-dir <path> --color <c> [--display-name <n>] [--link-to <account>]
  remove <name>
  current                                   Detect from CLAUDE_CONFIG_DIR
  unlink <name>                             Copy shared files so account is standalone
  link <name> [--to <account>]              Symlink files back to shared account (default: master ~/.claude)
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


LINKABLE = ["plugins", "settings.json"]


def link_account(target_dir: str, source_dir: str):
    """Symlink plugins/ and settings.json from target to source account."""
    target = os.path.expanduser(target_dir)
    source = os.path.expanduser(source_dir)
    linked = []
    for item in LINKABLE:
        src_path = os.path.join(source, item)
        tgt_path = os.path.join(target, item)
        if not os.path.exists(src_path):
            print(f"  ⚠ Source {src_path} does not exist, skipping")
            continue
        if os.path.islink(tgt_path):
            os.unlink(tgt_path)
        elif os.path.exists(tgt_path):
            backup = tgt_path + ".bak"
            os.rename(tgt_path, backup)
            print(f"  Backed up {item} → {item}.bak")
        os.symlink(src_path, tgt_path)
        linked.append(item)
        print(f"  ✓ Linked {item} → {src_path}")
    return linked


def unlink_account(target_dir: str):
    """Replace symlinks with copies so the account is standalone."""
    import shutil

    target = os.path.expanduser(target_dir)
    unlinked = []
    for item in LINKABLE:
        tgt_path = os.path.join(target, item)
        if not os.path.islink(tgt_path):
            print(f"  ⚠ {item} is not a symlink, skipping")
            continue
        real_path = os.path.realpath(tgt_path)
        if not os.path.exists(real_path):
            print(f"  ⚠ {item} symlink target does not exist, removing broken link")
            os.unlink(tgt_path)
            continue
        os.unlink(tgt_path)
        if os.path.isdir(real_path):
            shutil.copytree(real_path, tgt_path)
        else:
            shutil.copy2(real_path, tgt_path)
        unlinked.append(item)
        print(f"  ✓ Unlinked {item} (copied from {real_path})")
    return unlinked


def alias_for(name: str, config_dir: str) -> str:
    return f"claude-{name}"


def alias_cmd(name: str, config_dir: str) -> str:
    return f"CLAUDE_CONFIG_DIR={config_dir} claude --dangerously-skip-permissions"


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
            suggestions.append(f"    alias {alias}='{alias_cmd(name, config_dir)}'")

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
    parser.add_argument(
        "--link-to",
        default=None,
        help="Account name to link plugins/ and settings.json from",
    )
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

    if parsed.link_to:
        if parsed.link_to not in accounts:
            print(
                f"Error: account '{parsed.link_to}' not found to link to",
                file=sys.stderr,
            )
            sys.exit(1)
        source_dir = accounts[parsed.link_to]["config_dir"]
        print(f"\nLinking to '{parsed.link_to}' ({source_dir}):")
        link_account(config_dir, source_dir)

    accounts[name] = {
        "display_name": display_name,
        "config_dir": config_dir,
        "color": color,
    }
    save_accounts(accounts)

    alias = alias_for(name, config_dir)
    print(f"\nAdded account '{name}' ({display_name})")
    print("\nAdd to your shell profile:")
    print(f"  alias {alias}='{alias_cmd(name, config_dir)}'")

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


COLOR_DISPLAY = {
    "blue": "\033[34m●\033[0m blue",
    "green": "\033[32m●\033[0m green",
    "orange": "\033[33m●\033[0m orange",
    "red": "\033[31m●\033[0m red",
    "purple": "\033[35m●\033[0m purple",
    "yellow": "\033[93m●\033[0m yellow",
}


def prompt(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    try:
        val = input(f"  {label}{suffix}: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(0)
    return val or default


def cmd_setup():
    print()
    print("  Account Setup Wizard")
    print("  " + "─" * 40)
    print("  Add one account at a time. Press Enter to accept defaults.")
    print("  Leave name blank when done.")
    print()

    accounts = load_accounts()
    added = []

    while True:
        name = prompt("Account name (e.g. personal, work, edu) or blank to finish")
        if not name:
            break

        default_dir = "~/.claude" if name == "personal" else f"~/.claude-{name}"
        config_dir = prompt("Config dir", default_dir)
        expanded = os.path.expanduser(config_dir)
        if not os.path.isdir(expanded):
            try:
                create = (
                    input(f"  '{config_dir}' doesn't exist. Create it? [Y/n]: ")
                    .strip()
                    .lower()
                )
            except (EOFError, KeyboardInterrupt):
                print()
                sys.exit(0)
            if create in ("", "y", "yes"):
                os.makedirs(expanded, exist_ok=True)
                print(f"  Created {config_dir}")
            else:
                print("  Skipping.")
                print()
                continue

        print(f"  Colors: {', '.join(COLOR_DISPLAY[c] for c in sorted(VALID_COLORS))}")
        color_defaults = {"personal": "blue", "work": "green", "edu": "orange"}
        default_color = color_defaults.get(name, "blue")
        while True:
            color = prompt("Color", default_color)
            if color in VALID_COLORS:
                break
            print(f"  Invalid color. Choose from: {', '.join(sorted(VALID_COLORS))}")

        display_name = prompt("Display name", name.capitalize())

        # Offer to link plugins/settings from an existing account
        existing = [n for n in list(accounts.keys()) + added if n != name]
        if existing:
            print("  Link plugins & settings from an existing account?")
            print(f"  Available: {', '.join(existing)} (blank to skip)")
            link_target = prompt("Link to account", "").strip()
            if link_target and link_target in accounts:
                source_dir = accounts[link_target]["config_dir"]
                link_account(config_dir, source_dir)

        accounts[name] = {
            "display_name": display_name,
            "config_dir": config_dir,
            "color": color,
        }
        added.append(name)
        print(f"  ✓ Added '{name}'")
        print()

    if not added:
        print("  No accounts added.")
        print()
        return

    save_accounts(accounts)
    notify_daemon()

    print()
    print("  Done! Accounts registered:")
    aliases = []
    for name in added:
        info = accounts[name]
        alias = alias_for(name, info["config_dir"])
        print(f"  ● {name} ({info['display_name']})  →  {alias}")
        aliases.append(f"alias {alias}='{alias_cmd(name, info['config_dir'])}'")

    if aliases:
        print()
        print("  Add to your shell profile (~/.zshrc or ~/.bashrc):")
        for a in aliases:
            print(f"    {a}")
    print()


MASTER_DIR = "~/.claude"


def cmd_unlink(args):
    if not args:
        print("Error: missing account name", file=sys.stderr)
        sys.exit(1)
    name = args[0]

    accounts = load_accounts()
    if name not in accounts:
        print(f"Error: account '{name}' not found", file=sys.stderr)
        sys.exit(1)

    config_dir = accounts[name]["config_dir"]
    expanded = os.path.expanduser(config_dir)

    # Check if there's anything to unlink
    has_links = any(os.path.islink(os.path.join(expanded, item)) for item in LINKABLE)
    if not has_links:
        print(f"Account '{name}' has no linked files — already standalone.")
        return

    print(f"\nUnlinking account '{name}' ({config_dir}):")
    unlinked = unlink_account(config_dir)
    if unlinked:
        print(
            f"\nAccount '{name}' is now standalone. Edit files directly in {config_dir}"
        )
    else:
        print("\nNothing to unlink.")


def cmd_link(args):
    import argparse

    parser = argparse.ArgumentParser(prog="accounts.py link")
    parser.add_argument("name")
    parser.add_argument(
        "--to",
        default=None,
        help="Account name or path to link to (default: ~/.claude)",
    )
    parsed = parser.parse_args(args)

    accounts = load_accounts()
    if parsed.name not in accounts:
        print(f"Error: account '{parsed.name}' not found", file=sys.stderr)
        sys.exit(1)

    config_dir = accounts[parsed.name]["config_dir"]

    if parsed.to:
        if parsed.to in accounts:
            source_dir = accounts[parsed.to]["config_dir"]
        else:
            source_dir = parsed.to
    else:
        source_dir = MASTER_DIR

    source_expanded = os.path.expanduser(source_dir)
    if not os.path.isdir(source_expanded):
        print(f"Error: source '{source_dir}' does not exist", file=sys.stderr)
        sys.exit(1)

    target_expanded = os.path.expanduser(config_dir)
    if os.path.realpath(target_expanded) == os.path.realpath(source_expanded):
        print("Error: cannot link account to itself", file=sys.stderr)
        sys.exit(1)

    print(f"\nLinking account '{parsed.name}' ({config_dir}) → {source_dir}:")
    linked = link_account(config_dir, source_dir)
    if linked:
        print(f"\nAccount '{parsed.name}' now shares config with {source_dir}")
    else:
        print("\nNothing to link.")


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
    elif command == "setup":
        cmd_setup()
    elif command == "unlink":
        cmd_unlink(rest)
    elif command == "link":
        cmd_link(rest)
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
