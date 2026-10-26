import json
import os
import stat

from relay.store import Store


def test_alias_round_trip_clear_atomic_permissions(tmp_path):
    store = Store(tmp_path / "relay-state")
    store.set_alias("codex", "a1", "  API timeout  ")
    assert store.get_alias("codex", "a1") == "API timeout"
    assert stat.S_IMODE(os.stat(store.path).st_mode) == 0o600
    payload = json.loads(store.path.read_text())
    assert payload == {"aliases": {"codex:a1": "API timeout"}}
    store.set_alias("codex", "a1", " ")
    assert store.get_alias("codex", "a1") is None


def test_apply_alias_precedence_and_collision_safe_names(tmp_path):
    store = Store(tmp_path)
    store.set_alias("claude", "id2", "My chosen name")
    snapshot = {"sessions": [
        {"provider": "codex", "id": "parent-123456", "suggested_name": "API · agent · Fix endpoint"},
        {"provider": "codex", "id": "child-123456", "suggested_name": "API · agent · Fix endpoint"},
        {"provider": "claude", "id": "id2", "suggested_name": "API · main · Fix endpoint"},
    ], "providers": [], "total": 3}
    result = store.apply(snapshot)
    assert result["sessions"][0]["display_name"] != result["sessions"][1]["display_name"]
    assert result["sessions"][0]["display_name"].endswith("t123456")
    assert result["sessions"][1]["display_name"].endswith("d123456")
    assert result["sessions"][2]["display_name"] == "My chosen name"
    assert result["sessions"][2]["alias"] == "My chosen name"
    assert snapshot["sessions"][0].get("display_name") is None
