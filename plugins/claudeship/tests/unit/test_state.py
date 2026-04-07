import json
import os
import threading


# ── read_state ────────────────────────────────────────────────────────────────


def test_read_state_corrupt_file_returns_empty(state_file, capsys):
    import state

    with open(state.STATE_PATH, "w") as f:
        f.write("not valid json {{{")

    result = state.read_state()
    assert result == {}
    assert "corrupt" in capsys.readouterr().err


# ── write_state ───────────────────────────────────────────────────────────────


def test_write_state_creates_file_with_defaults(state_file):
    import state

    state.write_state({})

    assert os.path.exists(state.STATE_PATH)
    data = json.loads(open(state.STATE_PATH).read())
    assert "active_workspace" in data
    assert "usage" in data
    assert "daily" in data["usage"]
    assert "weekly" in data["usage"]
    assert "monthly" in data["usage"]


def test_write_state_nested_merge(state_file):
    """Partial nested update preserves sibling keys — the core contract."""
    import state

    state.write_state(
        {
            "usage": {
                "daily": {
                    "cost": 1.0,
                    "input_tokens": 100,
                    "output_tokens": 50,
                    "cache_read_tokens": 0,
                }
            }
        }
    )
    state.write_state({"usage": {"daily": {"cost": 2.5}}})

    daily = state.read_state()["usage"]["daily"]
    assert daily["cost"] == 2.5
    assert daily["input_tokens"] == 100  # must survive the second write
    assert daily["output_tokens"] == 50


def test_write_state_leaf_overwrites(state_file):
    import state

    state.write_state({"active_workspace": "ws-a"})
    state.write_state({"active_workspace": "ws-b"})

    assert state.read_state()["active_workspace"] == "ws-b"


def test_write_state_is_atomic(state_file):
    """File must contain valid JSON immediately after every write."""
    import state

    for i in range(20):
        state.write_state({"counter": i})
        raw = open(state.STATE_PATH).read()
        parsed = json.loads(raw)  # raises if corrupt
        assert parsed["counter"] == i


def test_write_state_creates_parent_dirs(tmp_path, monkeypatch):
    import state

    deep_path = str(tmp_path / "a" / "b" / "c" / "state.json")
    monkeypatch.setattr(state, "STATE_PATH", deep_path)
    state.write_state({"x": 1})
    assert os.path.exists(deep_path)


def test_concurrent_writes_dont_corrupt(state_file):
    """fcntl locking must prevent corruption when multiple sessions write at once."""
    import state

    errors = []

    def writer(i):
        try:
            state.write_state({"writer": i, "payload": "x" * 500})
        except Exception as e:
            errors.append(e)

    threads = [threading.Thread(target=writer, args=(i,)) for i in range(20)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors, f"Concurrent write raised: {errors}"
    # File must still be valid JSON after all concurrent writes
    data = state.read_state()
    assert isinstance(data, dict)
    assert "writer" in data


# ── _deep_merge ───────────────────────────────────────────────────────────────


def test_deep_merge_nested_dict(state_file):
    """Nested dicts merge recursively — not replaced wholesale."""
    import state

    base = {"outer": {"x": 1, "y": 2}}
    update = {"outer": {"y": 99, "z": 3}}
    result = state._deep_merge(base, update)
    assert result == {"outer": {"x": 1, "y": 99, "z": 3}}
