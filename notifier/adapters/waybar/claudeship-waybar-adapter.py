#!/usr/bin/env python3
"""
Waybar adapter for claudeship-notifier.

Reads /tmp/claudeship-status.json and outputs Waybar-compatible JSON.
Designed to be called by Waybar's custom module with:
    "interval": "once", "signal": 8
The daemon signals Waybar (SIGRTMIN+8) on every state change.
"""

import json
import sys

STATUS_PATH = "/tmp/claudeship-status.json"

try:
    with open(STATUS_PATH) as f:
        state = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    print(json.dumps({"text": "", "class": "empty"}))
    sys.exit(0)

# Build tooltip from sessions list
tooltip_lines = []
for s in state.get("sessions", []):
    if s.get("working"):
        icon = state.get("spinner_frame", "⣷")
        tool = f" {s['tool']}:{s.get('cmd', '')}" if s.get("tool") else ""
        tooltip_lines.append(f"{icon} {s['display']}{tool}")
    elif s.get("done"):
        tooltip_lines.append(f"✓ {s['display']}")
    else:
        tooltip_lines.append(f"○ {s['display']}")

    # Show subagent groups indented
    for g in s.get("agent_groups", []):
        count = f" ×{g['count']}" if g["count"] > 1 else ""
        tooltip_lines.append(f"  ↳ {g['type']}{count}")

# Add account info to tooltip if available
if s_list := state.get("sessions", []):
    accounts = {s["account"] for s in s_list if s.get("account")}
    if accounts:
        tooltip_lines.append("")
        tooltip_lines.append(f"Accounts: {', '.join(sorted(accounts))}")

print(
    json.dumps(
        {
            "text": state.get("text", ""),
            "tooltip": "\n".join(tooltip_lines) if tooltip_lines else "",
            "class": state.get("state", "empty"),
        }
    )
)
