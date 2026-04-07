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


# Pricing per million tokens: (input, output, cache_read, cache_write)
_PRICING = {
    "claude-opus-4": (15.00, 75.00, 1.500, 18.750),
    "claude-sonnet-4": (3.00, 15.00, 0.300, 3.750),
    "claude-haiku-4": (0.80, 4.00, 0.080, 1.000),
}
_PRICING_DEFAULT = _PRICING["claude-sonnet-4"]


def _model_pricing(model: str) -> tuple:
    for prefix, rates in _PRICING.items():
        if model.startswith(prefix):
            return rates
    return _PRICING_DEFAULT


def _estimate_cost(entry: dict) -> float:
    """Estimate cost from token usage."""
    if entry.get("type") != "assistant":
        return 0.0

    model = entry.get("message", {}).get("model", "")
    usage = entry.get("message", {}).get("usage", {}) or {}
    inp = usage.get("input_tokens", 0) or 0
    out = usage.get("output_tokens", 0) or 0
    cr = usage.get("cache_read_input_tokens", 0) or 0
    cw = usage.get("cache_creation_input_tokens", 0) or 0

    p_inp, p_out, p_cr, p_cw = _model_pricing(model)
    return (inp * p_inp + out * p_out + cr * p_cr + cw * p_cw) / 1_000_000


def compute_daily_history(projects_dir: str, now: datetime) -> dict:
    """Compute per-day cost for every day of the current month. Returns {day_number: cost}."""
    import calendar

    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    month_start = today_start.replace(day=1)
    days_in_month = calendar.monthrange(now.year, now.month)[1]

    daily = {d: 0.0 for d in range(1, days_in_month + 1)}

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
                        if entry.get("type") != "assistant":
                            continue
                        ts = parse_ts(entry.get("timestamp"))
                        if ts is None:
                            continue
                        if ts >= month_start and ts < month_start.replace(
                            day=days_in_month,
                            hour=23,
                            minute=59,
                            second=59,
                            microsecond=999999,
                        ) + timedelta(microseconds=1):
                            cost = _estimate_cost(entry)
                            if cost:
                                daily[ts.day] += cost
            except OSError:
                continue

    return daily


def _heat_color(cost: float, max_cost: float) -> str:
    """Return ANSI background color escape for a cost level (green gradient)."""
    if max_cost <= 0 or cost <= 0:
        return "\033[48;5;236m"  # dark gray for $0
    ratio = min(cost / max_cost, 1.0)
    # 5-stop green gradient: dark → bright
    stops = [22, 28, 34, 40, 46]
    idx = ratio * (len(stops) - 1)
    color = stops[min(int(idx + 0.5), len(stops) - 1)]
    return f"\033[48;5;{color}m"


_RESET = "\033[0m"


def render_chart(
    daily: dict, now: datetime, total_cost: float, label: str, weekly_limit: float = 0
):
    """Render a heatmap calendar of daily costs."""
    import calendar

    days_in_month = calendar.monthrange(now.year, now.month)[1]
    today = now.day
    first_weekday = calendar.weekday(now.year, now.month, 1)

    max_cost = max(daily.values()) if daily else 0
    if max_cost == 0:
        max_cost = 1.0

    cell_w = 5  # width per day cell
    month_name = now.strftime("%B %Y")
    print()
    print(f"  {label} — {month_name}")
    print()

    # Header
    days_header = "  "
    for name in ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]:
        days_header += f"{name:^{cell_w}}"
    print(days_header)

    # Build weeks
    d = 1
    dow = first_weekday  # 0=Monday

    while d <= days_in_month:
        block_row = "  "
        value_row = "  "
        week_cost = 0.0

        # Leading blanks
        for _ in range(dow):
            block_row += " " * cell_w
            value_row += " " * cell_w

        for col in range(dow, 7):
            if d > days_in_month:
                block_row += " " * cell_w
                value_row += " " * cell_w
            elif d > today:
                block_row += f"{'':^{cell_w}}"
                value_row += f"{'—':^{cell_w}}"
                d += 1
            else:
                cost = daily[d]
                week_cost += cost
                color = _heat_color(cost, max_cost)
                block_row += f" {color}   {_RESET} "
                if cost >= 100:
                    val = f"${cost:.0f}"
                elif cost > 0:
                    val = f"${cost:.0f}"
                else:
                    val = "$0"
                value_row += f"{val:^{cell_w}}"
                d += 1

        # Weekly summary
        if weekly_limit > 0 and week_cost > 0:
            pct = (week_cost / weekly_limit) * 100
            week_summary = f"  ${week_cost:>5.0f}  ({pct:.0f}%)"
        elif week_cost > 0:
            week_summary = f"  ${week_cost:>5.0f}"
        else:
            week_summary = ""

        print(block_row + week_summary)
        print(value_row)
        dow = 0

    print()
    if weekly_limit > 0:
        monthly_limit = weekly_limit * 4
        pct = (total_cost / monthly_limit) * 100
        print(f"  Total: ${total_cost:,.2f} / ${monthly_limit:,.0f}  ({pct:.0f}%)")
    else:
        print(f"  Total: ${total_cost:,.2f}")
    print()


def compute_usage(projects_dir: str, now: datetime) -> dict:
    """Compute usage buckets from JSONL files. Returns daily/weekly/monthly dicts."""
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

                        if entry.get("type") != "assistant":
                            continue

                        ts = parse_ts(entry.get("timestamp"))
                        if ts is None:
                            continue

                        cost = _estimate_cost(entry)
                        if not cost:
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

    for b in buckets.values():
        b["cost"] = round(b["cost"], 6)

    return buckets


def load_accounts() -> dict:
    path = os.path.expanduser("~/.claude/accounts.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
        return data.get("accounts", {})
    except Exception:
        return {}


def main():
    use_json = "--json" in sys.argv
    use_detail = "--detail" in sys.argv
    use_history = "--history" in sys.argv
    now = datetime.now(timezone.utc)

    accounts = load_accounts()

    # Compute per-account usage
    per_account = {}
    for name, info in accounts.items():
        config_dir = os.path.expanduser(info.get("config_dir", ""))
        projects_dir = os.path.join(config_dir, "projects")
        per_account[name] = compute_usage(projects_dir, now)

    # Aggregate totals across all accounts (or fall back to default path)
    if per_account:
        totals = {
            period: {
                "cost": sum(per_account[a][period]["cost"] for a in per_account),
                "input_tokens": sum(
                    per_account[a][period]["input_tokens"] for a in per_account
                ),
                "output_tokens": sum(
                    per_account[a][period]["output_tokens"] for a in per_account
                ),
                "cache_read_tokens": sum(
                    per_account[a][period]["cache_read_tokens"] for a in per_account
                ),
            }
            for period in ("daily", "weekly", "monthly")
        }
        for period in totals:
            totals[period]["cost"] = round(totals[period]["cost"], 6)
    else:
        totals = compute_usage(os.path.expanduser("~/.claude/projects"), now)

    write_state(
        {
            "usage": {
                "daily": totals["daily"],
                "weekly": totals["weekly"],
                "monthly": totals["monthly"],
                "updated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "accounts": {
                    name: {
                        "daily": per_account[name]["daily"],
                        "weekly": per_account[name]["weekly"],
                        "monthly": per_account[name]["monthly"],
                    }
                    for name in per_account
                },
            }
        }
    )

    if use_history:
        if per_account:
            for name, info in accounts.items():
                config_dir = os.path.expanduser(info.get("config_dir", ""))
                projects_dir = os.path.join(config_dir, "projects")
                acct_daily = compute_daily_history(projects_dir, now)
                total = sum(acct_daily.values())
                display = info.get("display_name", name)
                monthly_limit = info.get("monthly_limit", 0)
                weekly_limit = monthly_limit / 4 if monthly_limit else 0
                render_chart(acct_daily, now, total, display, weekly_limit)
        else:
            daily = compute_daily_history(os.path.expanduser("~/.claude/projects"), now)
            total = sum(daily.values())
            render_chart(daily, now, total, "Claude Code")
        return

    if use_json:
        output = {"accounts": {}, "total": {}}
        for name, buckets in per_account.items():
            output["accounts"][name] = {}
            for period in ("daily", "weekly", "monthly"):
                b = buckets[period]
                output["accounts"][name][period] = {
                    "cost": b["cost"],
                    "input_tokens": b["input_tokens"],
                    "output_tokens": b["output_tokens"],
                    "cache_read_tokens": b["cache_read_tokens"],
                    "total_tokens": b["input_tokens"] + b["output_tokens"],
                }
        for period in ("daily", "weekly", "monthly"):
            b = totals[period]
            output["total"][period] = {
                "cost": b["cost"],
                "input_tokens": b["input_tokens"],
                "output_tokens": b["output_tokens"],
                "cache_read_tokens": b["cache_read_tokens"],
                "total_tokens": b["input_tokens"] + b["output_tokens"],
            }
        print(json.dumps(output, indent=2))
    else:
        periods = [("Today", "daily"), ("Week", "weekly"), ("Month", "monthly")]
        print()
        print("  Claude Code Usage")

        if per_account:
            name_w = (
                max(
                    max(len(accounts[n].get("display_name", n)) for n in per_account),
                    len("Account"),
                )
                + 2
            )

            if use_detail:
                rule_w = name_w + 2 + 10 + 2 + 7 + 2 + 7 + 2 + 7
                for label, period_key in periods:
                    print()
                    print(f"  {label}")
                    print("  " + "─" * rule_w)
                    print(
                        f"  {'Account':<{name_w}}  {'Cost':>10}  {'Input':>7}  {'Output':>7}  {'Cache':>7}"
                    )
                    print("  " + "─" * rule_w)
                    for name in per_account:
                        b = per_account[name][period_key]
                        display = accounts[name].get("display_name", name)
                        print(
                            f"  {display:<{name_w}}  $ {b['cost']:>6.2f}  {fmt_tokens(b['input_tokens']):>7}  {fmt_tokens(b['output_tokens']):>7}  {fmt_tokens(b['cache_read_tokens']):>7}"
                        )
                    print("  " + "─" * rule_w)
                    b = totals[period_key]
                    print(
                        f"  {'Total':<{name_w}}  $ {b['cost']:>6.2f}  {fmt_tokens(b['input_tokens']):>7}  {fmt_tokens(b['output_tokens']):>7}  {fmt_tokens(b['cache_read_tokens']):>7}"
                    )
                print()
            else:
                col_w = 10
                rule_w = name_w + (col_w + 2) * 3 + 2
                print("  " + "─" * rule_w)
                print(
                    f"  {'Account':<{name_w}}  {'Today':>{col_w}}  {'Week':>{col_w}}  {'Month':>{col_w}}"
                )
                print("  " + "─" * rule_w)
                for name in per_account:
                    display = accounts[name].get("display_name", name)
                    cols = [
                        f"$ {per_account[name][p]['cost']:>6.2f}" for _, p in periods
                    ]
                    print(
                        f"  {display:<{name_w}}  {cols[0]:>{col_w}}  {cols[1]:>{col_w}}  {cols[2]:>{col_w}}"
                    )
                print("  " + "─" * rule_w)
                total_cols = [f"$ {totals[p]['cost']:>6.2f}" for _, p in periods]
                print(
                    f"  {'Total':<{name_w}}  {total_cols[0]:>{col_w}}  {total_cols[1]:>{col_w}}  {total_cols[2]:>{col_w}}"
                )
                print()
        else:
            print("  " + "─" * 44)
            print(
                f"  {'Period':<8}  {'Cost':<10}  {'Input':>7}  {'Output':>7}  {'Cache':>7}"
            )
            print("  " + "─" * 44)
            for label, key in periods:
                b = totals[key]
                print(
                    f"  {label:<8}  $ {b['cost']:>6.2f}  {fmt_tokens(b['input_tokens']):>7}  {fmt_tokens(b['output_tokens']):>7}  {fmt_tokens(b['cache_read_tokens']):>7}"
                )
            print()


if __name__ == "__main__":
    main()
