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
import subprocess


def get_git_branch(cwd: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "branch", "--show-current"],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=2,
        )
        branch = result.stdout.strip()
        return branch or None
    except Exception:
        return None


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

    display_name = current_info.get("display_name") or current_account or ""
    color_name = current_info.get("color", "")
    ansi_colors = {
        "blue": "\033[34m",
        "green": "\033[32m",
        "orange": "\033[33m",
        "red": "\033[31m",
        "purple": "\033[35m",
        "yellow": "\033[93m",
    }
    reset = "\033[0m"
    dot = "\033[90m · \033[0m"
    color_code = ansi_colors.get(color_name, "")

    segments = []

    if display_name:
        segments.append(f"\033[1m{color_code}{display_name}{reset}")

    # CWD + branch
    cwd = stdin_data.get("cwd", "")
    if cwd:
        home = os.path.expanduser("~")
        cwd_display = ("~" + cwd[len(home) :]) if cwd.startswith(home) else cwd
        branch = get_git_branch(cwd)
        loc = f"\033[1;96m{cwd_display}{reset}"
        if branch:
            loc += f" \033[1;92m{branch}{reset}"
        segments.append(loc)

    # Model name
    model_display = stdin_data.get("model", {}).get("display_name") or ""
    if model_display:
        segments.append(f"\033[1;95m{model_display}{reset}")

    # Context window usage (token count + percentage)
    ctx = stdin_data.get("context_window", {})
    ctx_pct = ctx.get("used_percentage")
    ctx_size = ctx.get("context_window_size")
    if ctx_pct is not None and ctx_size:
        pct = int(ctx_pct)
        used_tokens = int(ctx_size * ctx_pct / 100)
        # Format as "184k/1M" style
        if used_tokens >= 1_000_000:
            used_str = f"{used_tokens / 1_000_000:.1f}M"
        else:
            used_str = f"{used_tokens // 1000}k"
        if ctx_size >= 1_000_000:
            size_str = f"{ctx_size // 1_000_000}M"
        else:
            size_str = f"{ctx_size // 1000}k"
        if pct >= 80:
            ctx_color = "\033[31m"  # red
        elif pct >= 60:
            ctx_color = "\033[33m"  # yellow
        else:
            ctx_color = "\033[36m"  # cyan
        segments.append(f"\033[1m{ctx_color}{used_str}/{size_str} ({pct}%){reset}")

    prefix = dot.join(segments) + dot if segments else ""

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
            print(prefix + "\033[1;97m" + " · ".join(parts) + reset)

    else:
        # API account: read monthly cost from pre-computed state (written by usage.py)
        monthly_limit = current_info.get("monthly_limit")

        monthly_cost = 0.0
        state_path = os.path.expanduser("~/.claude/state.json")
        try:
            with open(state_path) as f:
                state = json.load(f)
            acct_data = (
                state.get("usage", {}).get("accounts", {}).get(current_account, {})
            )
            monthly_cost = acct_data.get("monthly", {}).get("cost", 0.0)
        except Exception:
            pass

        if monthly_limit:
            limit_str = (
                f"${int(monthly_limit)}"
                if monthly_limit == int(monthly_limit)
                else f"${monthly_limit}"
            )
            print(f"{prefix}\033[1;97m${monthly_cost:.2f} / {limit_str}{reset}")
        else:
            print(f"{prefix}\033[1;97m${monthly_cost:.2f} /mo{reset}")


if __name__ == "__main__":
    main()
