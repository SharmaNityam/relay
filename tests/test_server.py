import json
import os
import textwrap

from fastapi.testclient import TestClient

from relay import server


def test_demo_snapshot_is_labelled_synthetic_and_has_parent_child_statuses():
    snapshot = server.demo_snapshot()
    assert snapshot["demo"] is True
    assert snapshot["total"] == 6
    assert {s["status"] for s in snapshot["sessions"]} >= {"running", "waiting", "completed", "stale"}
    assert any(s["parent_id"] for s in snapshot["sessions"])
    assert all(s["status_source"] == "synthetic_demo" for s in snapshot["sessions"])


def test_dashboard_static_assets_are_served_from_root():
    client = TestClient(server.app)
    assert "Relay" in client.get("/").text
    assert "function refresh" in client.get("/app.js").text
    assert "@media" in client.get("/style.css").text


def test_local_api_security_and_demo_alias(monkeypatch, tmp_path):
    monkeypatch.setattr(server, "_store", server.Store(tmp_path))
    client = TestClient(server.app)
    response = client.get("/api/sessions?demo=1")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["content-security-policy"] == "frame-ancestors 'none'"
    assert response.json()["total"] == 6
    edited = client.patch("/api/sessions/codex/demo-codex/name", json={"name": "Build filters"})
    assert edited.status_code == 200
    assert edited.json()["display_name"] == "Build filters"
    assert client.get("/api/sessions?demo=1").json()["sessions"][0]["alias"] == "Build filters"
    assert client.patch("/api/sessions/codex/unknown/name", json={"name": "x"}).status_code == 404
    assert client.patch("/api/sessions/codex/demo-codex/name", json={"name": "x"},
                        headers={"Sec-Fetch-Site": "cross-site"}).status_code == 403
    assert client.get("/api/health", headers={"Host": "attacker.example"}).status_code == 400


def test_mutation_requires_json_and_caps_body():
    client = TestClient(server.app)
    response = client.patch("/api/sessions/codex/demo-codex/name", content="{}",
                            headers={"Content-Type": "text/plain"})
    assert response.status_code == 400
    response = client.patch("/api/sessions/codex/demo-codex/name", content=json.dumps({"name": "x" * 70000}),
                            headers={"Content-Type": "application/json"})
    assert response.status_code == 400


def test_cross_site_top_level_navigation_can_load_dashboard_but_not_api():
    client = TestClient(server.app)
    headers = {"Sec-Fetch-Site": "cross-site", "Sec-Fetch-Mode": "navigate", "Sec-Fetch-Dest": "document"}
    assert client.get("/", headers=headers).status_code == 200
    assert client.get("/api/sessions", headers=headers).status_code == 403


def test_native_sync_waits_for_initialize_before_renaming(tmp_path, monkeypatch):
    fake = tmp_path / "codex"
    fake.write_text(textwrap.dedent("""\
        #!/usr/bin/env python3
        import json, sys
        ready = False
        for line in sys.stdin:
            message = json.loads(line)
            if message.get('method') == 'initialize':
                print(json.dumps({'id': message['id'], 'result': {'ok': True}}), flush=True)
                ready = True
            elif message.get('method') == 'thread/name/set':
                assert ready
                print(json.dumps({'id': message['id'], 'result': {'ok': True}}), flush=True)
                break
    """), encoding="utf-8")
    fake.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ.get("PATH", ""))
    from relay.native_sync import rename_codex
    result = rename_codex("fixture-thread", "Fixture title")
    assert result == {"ok": True, "provider": "codex", "id": "fixture-thread", "name": "Fixture title"}
