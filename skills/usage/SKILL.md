---
name: usage
description: Show daily, weekly, and monthly Claude Code spend and token counts. Use when the user asks about usage, spend, costs, or tokens.
user-invocable: true
allowed-tools: Bash
argument-hint: [--detail|--history|--json]
---

# Usage

Run `python3 ${CLAUDE_PLUGIN_ROOT}/src/tools/usage.py $ARGUMENTS` and report the output. Shows daily, weekly, and monthly Claude Code spend and token counts.

Common flags:
- `--detail` — per-account breakdown
- `--history` — heatmap calendar
- `--json` — machine-readable output
