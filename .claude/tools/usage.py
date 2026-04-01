#!/usr/bin/env python3
import sys
import os
import json
import glob

sys.path.insert(0, os.path.dirname(__file__))
from state import write_state

from datetime import datetime, timezone, timedelta


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def fmt_tokens(n):
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    elif n >= 1000:
        return f"{n / 1000:.1f}k"
    return str(n)


def main():
    use_json = "--json" in sys.argv

    now = datetime.now(timezone.utc)
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=today_start.weekday())
    month_start = today_start.replace(day=1)

    buckets = {
        "daily": {
            "cost": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
        },
        "weekly": {
            "cost": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
        },
        "monthly": {
            "cost": 0.0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_read_tokens": 0,
        },
    }

    projects_dir = os.path.expanduser("~/.claude/projects")
    if os.path.isdir(projects_dir):
        pattern = os.path.join(projects_dir, "**", "*.jsonl")
        for jsonl_path in glob.glob(pattern, recursive=True):
            try:
                with open(jsonl_path, "r", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            entry = json.loads(line)
                        except json.JSONDecodeError:
                            continue

                        cost = entry.get("costUSD", 0)
                        if not (isinstance(cost, (int, float)) and cost > 0):
                            continue

                        ts = parse_ts(entry.get("timestamp"))
                        if ts is None:
                            continue

                        usage = entry.get("message", {}).get("usage", {}) or {}
                        inp = usage.get("input_tokens", 0) or 0
                        out = usage.get("output_tokens", 0) or 0
                        cache = usage.get("cache_read_input_tokens", 0) or 0

                        if ts >= month_start:
                            b = buckets["monthly"]
                            b["cost"] += cost
                            b["input_tokens"] += inp
                            b["output_tokens"] += out
                            b["cache_read_tokens"] += cache

                        if ts >= week_start:
                            b = buckets["weekly"]
                            b["cost"] += cost
                            b["input_tokens"] += inp
                            b["output_tokens"] += out
                            b["cache_read_tokens"] += cache

                        if ts >= today_start:
                            b = buckets["daily"]
                            b["cost"] += cost
                            b["input_tokens"] += inp
                            b["output_tokens"] += out
                            b["cache_read_tokens"] += cache
            except OSError:
                continue

    # Round costs
    for b in buckets.values():
        b["cost"] = round(b["cost"], 6)

    write_state(
        {
            "usage": {
                "daily": buckets["daily"],
                "weekly": buckets["weekly"],
                "monthly": buckets["monthly"],
                "updated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        }
    )

    if use_json:
        output = {}
        for period in ("daily", "weekly", "monthly"):
            b = buckets[period]
            output[period] = {
                "cost": b["cost"],
                "input_tokens": b["input_tokens"],
                "output_tokens": b["output_tokens"],
                "cache_read_tokens": b["cache_read_tokens"],
                "total_tokens": b["input_tokens"] + b["output_tokens"],
            }
        print(json.dumps(output, indent=2))
    else:
        labels = [("Today", "daily"), ("Week", "weekly"), ("Month", "monthly")]
        print()
        print("  Claude Code Usage")
        print("  " + "─" * 44)
        print(
            f"  {'Period':<8}  {'Cost':<10}  {'Input':>7}  {'Output':>7}  {'Cache':>7}"
        )
        print("  " + "─" * 44)
        for label, key in labels:
            b = buckets[key]
            cost_str = f"$ {b['cost']:>6.2f}"
            print(
                f"  {label:<8}  {cost_str:<10}  {fmt_tokens(b['input_tokens']):>7}  {fmt_tokens(b['output_tokens']):>7}  {fmt_tokens(b['cache_read_tokens']):>7}"
            )
        print()


if __name__ == "__main__":
    main()
