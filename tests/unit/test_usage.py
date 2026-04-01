import json
from datetime import datetime, timezone, timedelta

import pytest

from conftest import make_entry


# ── Fixtures & helpers ────────────────────────────────────────────────────────

NOW = datetime(2026, 4, 15, 15, 0, 0, tzinfo=timezone.utc)
# week_start = April 13 (Mon). month_start = April 1.


@pytest.fixture
def projects_dir(tmp_path):
    d = tmp_path / "projects" / "my-project"
    d.mkdir(parents=True)
    return tmp_path / "projects"


def write_jsonl(directory, filename, lines):
    path = directory / filename
    path.write_text("\n".join(lines) + "\n")


def ts(days_ago=0, hours_ago=0):
    """Return ISO timestamp relative to NOW."""
    dt = NOW - timedelta(days=days_ago, hours=hours_ago)
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


# ── Time bucketing ────────────────────────────────────────────────────────────


def test_today_entry_in_all_buckets(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    write_jsonl(proj, "session.jsonl", [make_entry(0.10, ts(days_ago=0))])
    buckets = compute_usage(str(projects_dir), NOW)
    assert buckets["daily"]["cost"] == pytest.approx(0.10)
    assert buckets["weekly"]["cost"] == pytest.approx(0.10)
    assert buckets["monthly"]["cost"] == pytest.approx(0.10)


def test_this_week_not_today_skips_daily(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    # NOW is Wednesday Apr 15; days_ago=1 is Tuesday Apr 14 — same week, not today
    write_jsonl(proj, "session.jsonl", [make_entry(0.20, ts(days_ago=1))])
    buckets = compute_usage(str(projects_dir), NOW)
    assert buckets["daily"]["cost"] == pytest.approx(0.0)
    assert buckets["weekly"]["cost"] == pytest.approx(0.20)
    assert buckets["monthly"]["cost"] == pytest.approx(0.20)


def test_this_month_not_this_week_skips_daily_and_weekly(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    # days_ago=7 = Apr 8; week_start is Apr 13 so Apr 8 is last week, same month
    write_jsonl(proj, "session.jsonl", [make_entry(0.30, ts(days_ago=7))])
    buckets = compute_usage(str(projects_dir), NOW)
    assert buckets["daily"]["cost"] == pytest.approx(0.0)
    assert buckets["weekly"]["cost"] == pytest.approx(0.0)
    assert buckets["monthly"]["cost"] == pytest.approx(0.30)


def test_old_entry_not_counted(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    write_jsonl(proj, "session.jsonl", [make_entry(1.00, ts(days_ago=45))])
    buckets = compute_usage(str(projects_dir), NOW)
    assert all(b["cost"] == 0.0 for b in buckets.values())


# ── Boundary timestamps (inclusive lower bound) ───────────────────────────────


def test_boundary_at_today_midnight_counts_as_today(state_file, projects_dir):
    """An entry timestamped at exactly today's midnight must land in daily."""
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    midnight = NOW.replace(hour=0, minute=0, second=0, microsecond=0)
    write_jsonl(
        proj, "s.jsonl", [make_entry(0.10, midnight.strftime("%Y-%m-%dT%H:%M:%SZ"))]
    )
    buckets = compute_usage(str(projects_dir), NOW)
    assert buckets["daily"]["cost"] == pytest.approx(0.10)


def test_boundary_at_week_start_counts_as_this_week(state_file, projects_dir):
    """An entry at exactly Monday 00:00 must land in weekly."""
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    today_start = NOW.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=today_start.weekday())  # Monday
    write_jsonl(
        proj, "s.jsonl", [make_entry(0.10, week_start.strftime("%Y-%m-%dT%H:%M:%SZ"))]
    )
    buckets = compute_usage(str(projects_dir), NOW)
    assert buckets["weekly"]["cost"] == pytest.approx(0.10)


def test_boundary_at_month_start_counts_as_this_month(state_file, projects_dir):
    """An entry at exactly the 1st of the month at 00:00 must land in monthly."""
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    month_start = NOW.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    write_jsonl(
        proj, "s.jsonl", [make_entry(0.10, month_start.strftime("%Y-%m-%dT%H:%M:%SZ"))]
    )
    buckets = compute_usage(str(projects_dir), NOW)
    assert buckets["monthly"]["cost"] == pytest.approx(0.10)


# ── Robustness ────────────────────────────────────────────────────────────────


def test_zero_cost_entry_skipped(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    write_jsonl(proj, "session.jsonl", [make_entry(0.0, ts()), make_entry(0.05, ts())])
    buckets = compute_usage(str(projects_dir), NOW)
    assert buckets["daily"]["cost"] == pytest.approx(0.05)


def test_missing_cost_field_skipped(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    line = json.dumps({"type": "assistant", "timestamp": ts()})
    write_jsonl(proj, "session.jsonl", [line])
    assert compute_usage(str(projects_dir), NOW)["daily"]["cost"] == 0.0


def test_malformed_json_line_skipped(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    write_jsonl(proj, "session.jsonl", ["{bad json", make_entry(0.10, ts())])
    assert compute_usage(str(projects_dir), NOW)["daily"]["cost"] == pytest.approx(0.10)


# ── Aggregation ───────────────────────────────────────────────────────────────


def test_multiple_files_and_projects(state_file, projects_dir):
    from usage import compute_usage

    for name in ("proj-a", "proj-b"):
        d = projects_dir / name
        d.mkdir()
        write_jsonl(d, "s.jsonl", [make_entry(0.10, ts())])
    assert compute_usage(str(projects_dir), NOW)["daily"]["cost"] == pytest.approx(0.20)


def test_token_counts_accumulated(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    write_jsonl(
        proj,
        "s.jsonl",
        [
            make_entry(0.10, ts(), input_tokens=1000, output_tokens=200, cache_read=50),
            make_entry(0.05, ts(), input_tokens=500, output_tokens=100, cache_read=25),
        ],
    )
    b = compute_usage(str(projects_dir), NOW)["daily"]
    assert b["input_tokens"] == 1500
    assert b["output_tokens"] == 300
    assert b["cache_read_tokens"] == 75


def test_costs_are_rounded_to_six_decimals(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    write_jsonl(proj, "s.jsonl", [make_entry(0.1 + 0.2, ts())])
    cost_str = str(compute_usage(str(projects_dir), NOW)["daily"]["cost"])
    assert len(cost_str.split(".")[-1]) <= 6


def test_json_output_keys_present(state_file, projects_dir):
    from usage import compute_usage

    proj = projects_dir / "proj"
    proj.mkdir()
    write_jsonl(
        proj, "s.jsonl", [make_entry(0.25, ts(), input_tokens=1000, output_tokens=200)]
    )
    buckets = compute_usage(str(projects_dir), NOW)
    for period in ("daily", "weekly", "monthly"):
        b = buckets[period]
        assert {
            "cost",
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
        } <= b.keys()
