---
name: account-link
description: Link a Claude Code account's settings and plugins back to a shared account (default ~/.claude).
user-invocable: true
allowed-tools: Bash
argument-hint: [account-name] [--to account-or-path]
---

# Account Link

Run `python3 ${CLAUDE_PLUGIN_ROOT}/src/tools/accounts.py link $ARGUMENTS` and report the result.

This symlinks `settings.json` and `plugins/` from the account to a shared source (defaults to `~/.claude`). Existing files are backed up as `.bak`.

Examples:
- `account-link work` — link work to ~/.claude (master)
- `account-link work --to personal` — link work to personal account's config dir
