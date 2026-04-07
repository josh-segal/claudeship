---
name: account-unlink
description: Unlink a Claude Code account so it has its own standalone settings and plugins (no longer shared via symlinks).
user-invocable: true
allowed-tools: Bash
argument-hint: [account-name]
---

# Account Unlink

Run `python3 ${CLAUDE_PLUGIN_ROOT}/src/tools/accounts.py unlink $ARGUMENTS` and report the result.

This replaces symlinked `settings.json` and `plugins/` with standalone copies, so the account can diverge from the shared config.

Example: `account-unlink work`
