#!/usr/bin/env python3
"""
Claude Code statusLine script.

Reads session JSON from stdin (provided by Claude Code) and outputs a
formatted usage string based on the current account:

  personal  →  "5h 42% · 7d 68%"   (Max subscription rate limits)
  work/edu  →  "$18.50 / $300"      (monthly API spend vs configured limit)

Account is detected via CLAUDE_CONFIG_DIR env var matched against accounts.json.
"""

import sys
import os
import json
import glob
from datetime import datetime, timezone


def main():
    try:
        stdin_data = json.loads(sys.stdin.read())
    except Exception:
        stdin_data = {}

    config_dir = os.path.realpath(
        os.path.expanduser(
            os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        )
    )

    accounts_path = os.path.expanduser("~/.claude/accounts.json")
    try:
        with open(accounts_path) as f:
            accounts = json.load(f).get("accounts", {})
    except Exception:
        accounts = {}

    current_account = None
    current_info = None
    for name, info in accounts.items():
        acct_dir = os.path.realpath(os.path.expanduser(info.get("config_dir", "")))
        if acct_dir == config_dir:
            current_account = name
            current_info = info
            break

    if current_info is None:
        return

    display_format = current_info.get("display_format", "dollar")

    if display_format == "percent":
        # Max/Pro subscription: use rate_limits from stdin JSON
        rate_limits = stdin_data.get("rate_limits", {})
        five_h = rate_limits.get("five_hour", {})
        seven_d = rate_limits.get("seven_day", {})
        five_pct = five_h.get("used_percentage")
        seven_pct = seven_d.get("used_percentage")

        parts = []
        if five_pct is not None:
            parts.append(f"5h {int(five_pct)}%")
        if seven_pct is not None:
            parts.append(f"7d {int(seven_pct)}%")

        if parts:
            print(" · ".join(parts))

    else:
        # API account: scan JSONL for current month's spend
        monthly_limit = current_info.get("monthly_limit")
        projects_dir = os.path.join(config_dir, "projects")

        now = datetime.now(timezone.utc)
        month_start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

        monthly_cost = 0.0
        if os.path.isdir(projects_dir):
            for path in glob.glob(
                os.path.join(projects_dir, "**", "*.jsonl"), recursive=True
            ):
                # Skip files not modified this month (fast path)
                try:
                    if os.path.getmtime(path) < month_start.timestamp():
                        continue
                except OSError:
                    continue
                try:
                    with open(path, errors="replace") as f:
                        for line in f:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                entry = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            cost = entry.get("costUSD", 0)
                            if not isinstance(cost, (int, float)) or cost <= 0:
                                continue
                            ts_str = entry.get("timestamp", "")
                            try:
                                ts = datetime.fromisoformat(
                                    ts_str.replace("Z", "+00:00")
                                )
                                if ts >= month_start:
                                    monthly_cost += cost
                            except (ValueError, AttributeError):
                                continue
                except OSError:
                    continue

        if monthly_limit:
            limit_str = (
                f"${int(monthly_limit)}"
                if monthly_limit == int(monthly_limit)
                else f"${monthly_limit}"
            )
            print(f"${monthly_cost:.2f} / {limit_str}")
        else:
            print(f"${monthly_cost:.2f} /mo")


if __name__ == "__main__":
    main()
