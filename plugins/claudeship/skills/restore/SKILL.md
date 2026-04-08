---
name: restore
description: View and restore git-based backups of your Claude config directory. List backups, diff changes, or restore files.
user-invocable: true
allowed-tools: Bash
argument-hint: [list|diff [N]|file <path>|all <N>]
---

# Restore

Run `python3 ${CLAUDE_PLUGIN_ROOT}/src/tools/backup.py $ARGUMENTS` and report the output to the user.

If no arguments are provided, run with `list` to show recent backups.

Subcommands:
- `list` — show recent backups with relative timestamps
- `diff [N]` — show what changed at backup N (default: most recent)
- `file <path>` — restore a specific file to its last backed-up version
- `all <N>` — restore entire config to the state at backup N
