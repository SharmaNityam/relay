"""Independent boundary tests. Fixtures never read personal provider state."""
import hashlib
import json
import os
import sqlite3
import time
import zipfile
from datetime import datetime, timedelta, timezone
from io import BytesIO
from pathlib import Path

import pytest

from relay import adapters
from relay.contracts import Session, Snapshot
from relay.store import Store


def stamp(delta=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=delta)).isoformat()


def jsonl(path, *records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(record) + "\n" for record in records))
    return path


def codex_path(home, name="run"):
    return home / "sessions/2026/10/26" / f"{name}.jsonl"


def meta(sid="thread", **extra):
    return {"type": "session_meta", "payload": {"id": sid, "cwd": "/repo/widget", **extra}}


def event(kind, when=None, **extra):
    return {"type": "event_msg", "timestamp": when or stamp(), "payload": {"type": kind, **extra}}


def user(sid, task="Repair widget", **extra):
    return {"type": "user", "sessionId": sid, "cwd": "/repo/widget", "timestamp": stamp(),
            "message": {"content": task}, **extra}


def test_truncated_tail_and_recent_mtime_do_not_complete_or_start(tmp_path):
    path = jsonl(codex_path(tmp_path), meta(), event("user_message", message="Investigate widget"))
    with path.open("ab") as file:
        file.write(b'{"type":"event_msg","payload":{"type":"task_complete"')
    os.utime(path, None)
    session = adapters.scan_codex(tmp_path, 20)[0]
    assert session.status == "unknown"
    assert "complete" not in session.status_source


@pytest.mark.parametrize("kind,wanted", [("task_complete", "completed"), ("task_aborted", "interrupted")])
def test_terminal_event_survives_bounded_middle_and_malformed_last_line(tmp_path, kind, wanted):
    path = jsonl(codex_path(tmp_path), meta(), event("task_started", stamp(-500)))
    with path.open("ab") as file:
        file.write((b'{"irrelevant":"' + b'x' * 40000 + b'"}\n') * 30)
        file.write((json.dumps(event(kind)) + "\n{broken").encode())
    assert path.stat().st_size > 1_000_000
    assert adapters.scan_codex(tmp_path, 10)[0].status == wanted


def test_future_and_stale_activity_have_honest_provenance(tmp_path):
    jsonl(codex_path(tmp_path, "old"), meta("old"), event("task_started", stamp(-500)))
    jsonl(codex_path(tmp_path, "future"), meta("future"), event("task_started", stamp(3600)))
    result = {s.id: s for s in adapters.scan_codex(tmp_path, 10)}
    assert result["old"].status == "stale"
    assert result["old"].status_source.startswith("inferred")
    assert result["future"].status == "unknown"
    assert "future" in result["future"].status_source


def test_known_codex_spawn_source_retains_real_parent(tmp_path):
    jsonl(codex_path(tmp_path), meta("child", source={"subagent": {"thread_spawn": {
        "parent_thread_id": "actual-parent", "depth": 2}}}))
    assert adapters.scan_codex(tmp_path, 10)[0].parent_id == "actual-parent"


def test_claude_children_have_unique_ids_even_when_session_id_is_parent(tmp_path):
    project = tmp_path / "projects/project"
    jsonl(project / "parent.jsonl", user("parent"))
    jsonl(project / "parent/subagents/agent-child-a.jsonl", user("parent", "Review auth", agentId="child-a"))
    jsonl(project / "parent/subagents/agent-child-b.jsonl", user("parent", "Test auth", agentId="child-b"))
    result = adapters.scan_claude(tmp_path, 20)
    assert len(result) == 3
    assert len({s.id for s in result}) == 3
    children = [s for s in result if s.parent_id]
    assert len(children) == 2 and all(s.parent_id == "parent" for s in children)
    assert len({s.suggested_name for s in children}) == 2


@pytest.mark.parametrize("provider,level", [("codex", "file"), ("codex", "directory"),
                                           ("claude", "file"), ("claude", "directory")])
def test_session_scan_does_not_follow_external_symlinks(tmp_path, provider, level):
    home, outside = tmp_path / "home", tmp_path / "outside"
    if provider == "codex":
        source = jsonl(outside / "escape.jsonl", meta("external-secret"))
        target = codex_path(home, "escape")
        if level == "directory":
            target = target.parent
            source = source.parent
    else:
        source = jsonl(outside / "escape.jsonl", user("external-secret"))
        target = home / "projects/p/escape.jsonl"
        if level == "directory":
            target = target.parent
            source = source.parent
    target.parent.mkdir(parents=True, exist_ok=True)
    target.symlink_to(source, target_is_directory=source.is_dir())
    scanner = adapters.scan_codex if provider == "codex" else adapters.scan_claude
    assert scanner(home, 10) == []


def test_zero_limit_applies_to_both_providers(tmp_path):
    jsonl(tmp_path / "projects/p/s.jsonl", user("s"))
    assert adapters.scan_claude(tmp_path, 0) == []


def test_database_metadata_uses_rollout_evidence_without_mutation_or_credential_fields(tmp_path):
    rollout = jsonl(codex_path(tmp_path), meta("db-id"), event("task_complete"))
    db = tmp_path / "state_5.sqlite"
    with sqlite3.connect(db) as con:
        con.execute("CREATE TABLE threads(id TEXT, title TEXT, rollout_path TEXT, updated_at INTEGER, api_key TEXT, credentials BLOB)")
        con.execute("INSERT INTO threads VALUES(?,?,?,?,?,?)", ("db-id", "Widget", str(rollout), 1,
                    "DO_NOT_EXPOSE_CREDENTIAL", b"PRIVATE_BINARY"))
    before = hashlib.sha256(db.read_bytes()).hexdigest()
    session = adapters.scan_codex(tmp_path, 10)[0]
    assert hashlib.sha256(db.read_bytes()).hexdigest() == before
    payload = json.dumps(session.to_dict())
    assert "DO_NOT_EXPOSE_CREDENTIAL" not in payload and "PRIVATE_BINARY" not in payload
    assert session.status == "completed"


def test_historical_sqlite_rows_are_not_running_and_archived_is_not_completion(tmp_path):
    db = tmp_path / "state_5.sqlite"
    with sqlite3.connect(db) as con:
        con.execute("CREATE TABLE threads(id TEXT, updated_at INTEGER, archived INTEGER)")
        con.executemany("INSERT INTO threads VALUES(?,?,?)", [(str(i), 1, i % 2) for i in range(200)])
    sessions = adapters.scan_codex(tmp_path, 7)
    assert len(sessions) == 7
    assert all(s.status == "unknown" for s in sessions)


def test_tool_arguments_and_unrelated_auth_files_are_never_returned(tmp_path):
    (tmp_path / "auth.json").write_text('{"token":"AUTH_CANARY_123456"}')
    jsonl(codex_path(tmp_path), meta(), event("user_message", message="Fix api_key=redact-this-value"),
          {"type": "response_item", "payload": {"type": "function_call", "name": "exec_command",
           "arguments": '{"command":"TOOL_COMMAND_CANARY_123456"}'}})
    result = json.dumps([s.to_dict() for s in adapters.scan_codex(tmp_path, 10)])
    assert all(secret not in result for secret in ("AUTH_CANARY_123456", "TOOL_COMMAND_CANARY_123456", "redact-this-value"))


def test_alias_persistence_is_provider_isolated_and_source_title_unchanged(tmp_path):
    store = Store(tmp_path)
    store.set_alias("codex", "shared", "Local title")
    store = Store(tmp_path)
    original = Snapshot([Session("codex", "shared", title="Original"), Session("claude", "shared", title="Original")]).to_dict()
    result = store.apply(original)
    assert result["sessions"][0]["display_name"] == "Local title"
    assert result["sessions"][1]["display_name"] == "Original"
    assert all(s["title"] == "Original" for s in result["sessions"])
    assert original["sessions"][0]["display_name"] == "Original"
    store.path.write_text('{"aliases":')
    assert store.get_alias("codex", "shared") is None


def test_automatic_names_remain_distinct_with_colliding_id_suffixes(tmp_path):
    snapshot = {"sessions": [{"provider": "codex", "id": ident, "title": "Repair widget"}
                              for ident in ("parent-123456", "child-123456")]}
    result = Store(tmp_path).apply(snapshot)
    assert len({s["display_name"] for s in result["sessions"]}) == 2


@pytest.mark.parametrize("provider", ["codex", "claude"])
def test_running_without_valid_timestamp_is_unknown(tmp_path, provider):
    if provider == "codex":
        jsonl(codex_path(tmp_path), meta(), {"type": "event_msg", "timestamp": "invalid", "payload": {"type": "task_started"}})
        session = adapters.scan_codex(tmp_path, 10)[0]
    else:
        jsonl(tmp_path / "projects/p/s.jsonl", {"type": "assistant", "timestamp": "invalid", "message": {
            "content": [{"type": "tool_use", "name": "Read"}]}})
        session = adapters.scan_claude(tmp_path, 10)[0]
    assert session.status == "unknown"


@pytest.mark.parametrize("provider", ["codex", "claude"])
def test_new_user_message_clears_previous_turn_completion(tmp_path, provider):
    if provider == "codex":
        jsonl(codex_path(tmp_path), meta(), event("task_complete", stamp(-30)), event("user_message", message="One more fix"))
        session = adapters.scan_codex(tmp_path, 10)[0]
    else:
        jsonl(tmp_path / "projects/p/s.jsonl", user("s"),
              {"type": "assistant", "timestamp": stamp(-30), "message": {"stop_reason": "end_turn", "content": "Done"}},
              user("s", "One more fix"))
        session = adapters.scan_claude(tmp_path, 10)[0]
    assert session.status != "completed"


def test_global_limit_keeps_both_available_providers_visible(tmp_path):
    codex, claude = tmp_path / "codex", tmp_path / "claude"
    for i in range(10):
        jsonl(codex_path(codex, str(i)), meta(str(i)))
        jsonl(claude / "projects/p" / f"{i}.jsonl", user(str(i)))
    sessions = adapters.collect_sessions(codex, claude, 4).sessions
    assert len(sessions) <= 4
    assert {s.provider for s in sessions} == {"codex", "claude"}


def test_recent_claude_child_is_not_hidden_by_historical_parents(tmp_path):
    project = tmp_path / "projects/p"
    for i in range(10):
        path = jsonl(project / f"old-{i}.jsonl", user(f"old-{i}"))
        os.utime(path, (1, 1))
    jsonl(project / "old-0/subagents/agent-active.jsonl", user("old-0", "Current work", agentId="active"))
    sessions = adapters.scan_claude(tmp_path, 3)
    assert any(s.parent_id == "old-0" for s in sessions)


@pytest.fixture
def api_client(monkeypatch, tmp_path):
    from fastapi.testclient import TestClient
    from relay import server
    monkeypatch.setattr(server, "_store", Store(tmp_path))
    monkeypatch.setattr(server, "_scan_at", 0.0)
    monkeypatch.setattr(server, "_scan_value", None)
    monkeypatch.setattr(server, "collect_sessions", lambda **kwargs: Snapshot([Session("codex", "known", title="Original")]))
    with TestClient(server.app, base_url="http://127.0.0.1:9778") as client:
        yield client


@pytest.mark.parametrize("origin", ["http://127.0.0.1", "https://127.0.0.1:9778", "http://127.0.0.1:9779",
                                    "null", "http://attacker.example", "http://127.0.0.1:9778/path"])
def test_api_rejects_cross_origin_mutations(api_client, origin):
    response = api_client.patch("/api/sessions/codex/known/name", json={"name": "Unauthorized change"}, headers={"Origin": origin})
    assert response.status_code == 403


@pytest.mark.parametrize("host", ["attacker.example", "localhost.evil.test:9778", "127.0.0.1:9778@evil.test", "127.0.0.1:9778/", "127.0.0.1:bad"])
def test_api_rejects_malformed_or_foreign_host(api_client, host):
    assert api_client.get("/api/sessions", headers={"Host": host}).status_code == 400


@pytest.mark.parametrize("body,content_type", [(b'\xff', "application/json"), (b'[]', "application/json"),
                                             (b'{"name":"hello"}', "text/plain"), (b'x' * 65537, "application/json")])
def test_api_body_boundaries(api_client, body, content_type):
    response = api_client.patch("/api/sessions/codex/known/name", content=body, headers={"Content-Type": content_type})
    assert response.status_code == 400


def test_alias_is_immediately_visible_and_isolated(api_client):
    assert api_client.get("/api/sessions").json()["sessions"][0]["display_name"] == "Original"
    response = api_client.patch("/api/sessions/codex/known/name", json={"name": "New title"})
    assert response.status_code == 200
    assert api_client.get("/api/sessions").json()["sessions"][0]["display_name"] == "New title"
    assert api_client.patch("/api/sessions/claude/known/name", json={"name": "Wrong provider"}).status_code == 404


def test_source_copy_rejects_external_symlinks_and_leaves_original_unchanged(tmp_path):
    from relay import repro
    source, outside, target = tmp_path / "repo", tmp_path / "private", tmp_path / "copy"
    source.mkdir()
    outside.mkdir()
    (source / "app.py").write_text("VALUE = 7\n")
    (outside / "secret.py").write_text('SECRET = "EXTERNAL_SECRET"\n')
    (source / "escape.py").symlink_to(outside / "secret.py")
    (source / "external").symlink_to(outside, target_is_directory=True)
    before = (source / "app.py").read_bytes()
    repro._copy_source(source, target)
    assert (source / "app.py").read_bytes() == before
    assert [p.relative_to(target).as_posix() for p in target.rglob("*") if p.is_file()] == ["app.py"]


def test_source_copy_enforces_aggregate_file_limit(tmp_path, monkeypatch):
    from relay import repro
    source = tmp_path / "repo"
    source.mkdir()
    for i in range(3):
        (source / f"{i}.py").write_text("VALUE = 1\n")
    monkeypatch.setattr(repro, "MAX_FILES", 2)
    with pytest.raises(ValueError, match="limits"):
        repro._copy_source(source, tmp_path / "copy")


@pytest.mark.parametrize("output", [
    "ERROR collecting test_relay_regression.py\nassert CONFIG_READY\nAssertionError\n1 error during collection",
    "ERROR at setup of test_regression\n@pytest.fixture\ndef setup():\n> assert False\nE AssertionError\n1 error",
    "ERROR at setup of test_regression\nfixture 'missing_resource' not found\n1 error",
])
def test_setup_failures_never_count_as_reproduced_assertions(tmp_path, monkeypatch, output):
    from relay import repro
    (tmp_path / "test_relay_regression.py").write_text("def test_regression(): assert False\n")
    monkeypatch.setattr(repro, "_docker_run", lambda work: (1, output, None))
    assert repro._run_test(tmp_path)["outcome"] == "setup_error"


def wait_job(manager, job_id):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        job = manager.get(job_id)
        if job["status"] not in {"queued", "running"}:
            return job
        time.sleep(0.01)
    pytest.fail("Repro job failed to settle within five seconds")


def test_demo_fix_rejects_changed_test_integrity(tmp_path, monkeypatch):
    from relay import repro
    monkeypatch.setattr(repro, "_docker_run", lambda work: (1, "FAILED: DID NOT RAISE", None))
    manager = repro.ReproManager(tmp_path)
    try:
        job = manager.create({"provider": "demo"})
        assert wait_job(manager, job["id"])["status"] == "reproduced"
        manager._jobs[job["id"]]["test_code"] = "def test_fake(): pass\n"
        with pytest.raises(ValueError, match="integrity"):
            manager.demo_fix(job["id"])
    finally:
        manager._pool.shutdown(wait=True)


def test_provider_workflow_copies_refreshes_preserves_test_and_exports_only_evidence(tmp_path, monkeypatch):
    from relay import repro
    source = tmp_path / "repo"
    source.mkdir()
    source_file = source / "app.py"
    source_file.write_text("VALUE = 0\n")
    code = "from app import VALUE\ndef test_value(): assert VALUE == 1\n"
    calls = []
    monkeypatch.setattr(repro, "_generate", lambda provider, issue, root: code)
    def fake_runner(work):
        snapshot = work / "source"
        actual_test = (snapshot / "test_relay_regression.py").read_text()
        calls.append(actual_test)
        assert actual_test == code
        assert snapshot != source
        return ((0, "1 passed", None) if "VALUE = 1" in (snapshot / "app.py").read_text()
                else (1, "FAILED test_value - AssertionError", None))
    monkeypatch.setattr(repro, "_docker_run", fake_runner)
    manager = repro.ReproManager(tmp_path / "state")
    try:
        job = manager.create({"provider": "openai", "repo_path": str(source), "issue": "Value must equal one"})
        assert wait_job(manager, job["id"])["status"] == "reproduced"
        assert source_file.read_text() == "VALUE = 0\n"
        assert list(source.iterdir()) == [source_file]
        source_file.write_text("VALUE = 1\n")
        manager.verify(job["id"])
        assert wait_job(manager, job["id"])["status"] == "verified"
        assert len(calls) == 2 and calls[0] == calls[1]
        blob, _ = manager.download(job["id"])
        with zipfile.ZipFile(BytesIO(blob)) as archive:
            assert set(archive.namelist()) == {"test_relay_regression.py", "report.json", "README.txt"}
            report = json.loads(archive.read("report.json"))
            assert report["test_hash"] == hashlib.sha256(archive.read("test_relay_regression.py")).hexdigest()
        assert source_file.read_text() == "VALUE = 1\n"
    finally:
        manager._pool.shutdown(wait=True)


def test_codex_database_symlink_and_external_rollout_are_not_read(tmp_path):
    home, outside = tmp_path / "home", tmp_path / "outside"
    home.mkdir()
    outside.mkdir()
    db = outside / "state_5.sqlite"
    with sqlite3.connect(db) as con:
        con.execute("CREATE TABLE threads(id TEXT)")
        con.execute("INSERT INTO threads VALUES('EXTERNAL_DATABASE')")
    (home / "state_5.sqlite").symlink_to(db)
    assert adapters.scan_codex(home, 10) == []
    (home / "state_5.sqlite").unlink()
    rollout = jsonl(outside / "run.jsonl", meta("local"), event("task_complete"))
    with sqlite3.connect(home / "state_5.sqlite") as con:
        con.execute("CREATE TABLE threads(id TEXT, rollout_path TEXT)")
        con.execute("INSERT INTO threads VALUES('local', ?)", (str(rollout),))
    assert adapters.scan_codex(home, 10)[0].status == "unknown"


@pytest.mark.parametrize("amount", [float("inf"), float("nan"), -1])
def test_invalid_reported_token_counts_do_not_crash_provider(tmp_path, amount):
    jsonl(codex_path(tmp_path), meta(), event("token_count", info={"total_token_usage": {"total_tokens": amount}}))
    session = adapters.scan_codex(tmp_path, 10)[0]
    assert session.tokens is None


def test_zero_reported_tokens_are_distinct_from_unavailable(tmp_path):
    jsonl(codex_path(tmp_path), meta(), event("token_count", info={"total_token_usage": {"total_tokens": 0}}))
    assert adapters.scan_codex(tmp_path, 10)[0].tokens == 0


def test_deeply_malformed_json_line_is_isolated(tmp_path):
    path = jsonl(codex_path(tmp_path), meta())
    with path.open("a") as file:
        file.write('[' * 2000 + '0' + ']' * 2000 + '\n')
    assert adapters.scan_codex(tmp_path, 10)[0].id == "thread"


def test_codex_native_sync_sends_only_name_rpc_and_does_not_inherit_provider_key(monkeypatch):
    from relay import native_sync
    class Sink(BytesIO):
        def close(self):
            self.sent = self.getvalue()
    requests = []
    responses = [b'{"id":1,"result":{}}\n', b'{"id":2,"result":{}}\n']
    class Output(BytesIO):
        def fileno(self):
            return 9999
    class Process:
        def __init__(self, args, **kwargs):
            requests.append((args, kwargs, self))
            self.stdin = Sink()
            self.stdout = Output()
        def wait(self, **kwargs):
            return 0
        def kill(self):
            self.killed = True
    monkeypatch.setenv("RELAY_MODEL_API_KEY", "PROVIDER_CANARY_123456")
    monkeypatch.setattr(native_sync.shutil, "which", lambda name: "/synthetic/codex")
    monkeypatch.setattr(native_sync.subprocess, "Popen", Process)
    monkeypatch.setattr(native_sync.select, "select", lambda reads, *args: (reads if responses else [], [], []))
    monkeypatch.setattr(native_sync.os, "read", lambda *args: responses.pop(0))
    result = native_sync.rename_codex("thread", "Safe title")
    assert result["ok"] is True
    args, kwargs, process = requests[0]
    assert args == ["/synthetic/codex", "app-server"]
    assert "RELAY_MODEL_API_KEY" not in kwargs["env"]
    messages = [json.loads(line) for line in process.stdin.getvalue().splitlines()]
    assert [message["method"] for message in messages] == ["initialize", "initialized", "thread/name/set"]
    assert messages[-1]["params"] == {"threadId": "thread", "name": "Safe title"}
    assert process.killed


def test_read_only_monitoring_and_local_alias_do_not_trigger_native_sync(api_client, monkeypatch):
    from relay import native_sync
    def forbidden(*args, **kwargs):
        pytest.fail("Read-only monitoring/local alias invoked native sync")
    monkeypatch.setattr(native_sync, "rename_codex", forbidden)
    assert api_client.get("/api/sessions").status_code == 200
    assert api_client.patch("/api/sessions/codex/known/name", json={"name": "Local"}).status_code == 200


docker_integration = pytest.mark.skipif(os.environ.get("RELAY_TEST_DOCKER") != "1",
                                       reason="Set RELAY_TEST_DOCKER=1 with relay-repro:local built to run actual Docker checks")


@docker_integration
def test_actual_docker_nonroot_readonly_network_resources_and_privileges(tmp_path):
    from relay import repro
    code = '''import os, socket
from pathlib import Path
import pytest

def test_sandbox_boundaries():
    assert os.geteuid() != 0
    assert os.statvfs('/').f_flag & os.ST_RDONLY
    assert os.statvfs('/workspace').f_flag & os.ST_RDONLY
    with pytest.raises(OSError):
        Path('/workspace/mutated.py').write_text('bad')
    with socket.socket() as connection:
        connection.settimeout(1)
        with pytest.raises(OSError):
            connection.connect(('1.1.1.1', 443))
    status = Path('/proc/self/status').read_text()
    assert 'NoNewPrivs:\\t1' in status
    assert int(next(line.split()[1] for line in status.splitlines() if line.startswith('CapEff:')), 16) == 0
    assert Path('/sys/fs/cgroup/memory.max').read_text().strip() == '268435456'
    assert Path('/sys/fs/cgroup/pids.max').read_text().strip() == '64'
'''
    (tmp_path / "test_relay_regression.py").write_text(code)
    result = repro._run_test(tmp_path)
    assert result["outcome"] == "passed", result
    assert not (tmp_path / "mutated.py").exists()


@docker_integration
def test_actual_docker_demo_fails_then_same_test_passes_after_fix(tmp_path):
    from relay import repro
    manager = repro.ReproManager(tmp_path)
    try:
        job = manager.create({"provider": "demo"})
        baseline = wait_job(manager, job["id"])
        assert baseline["status"] == "reproduced", baseline
        original = baseline["test_code"]
        manager.demo_fix(job["id"])
        result = wait_job(manager, job["id"])
        assert result["status"] == "verified", result
        assert result["test_code"] == original
        blob, _ = manager.download(job["id"])
        with zipfile.ZipFile(BytesIO(blob)) as archive:
            assert set(archive.namelist()) == {"test_relay_regression.py", "report.json", "README.txt"}
            assert archive.read("test_relay_regression.py").decode() == original
    finally:
        manager._pool.shutdown(wait=True)


@docker_integration
def test_actual_docker_timeout_removes_only_its_own_container(tmp_path, monkeypatch):
    from relay import repro
    (tmp_path / "test_relay_regression.py").write_text("import time\ndef test_sleep(): time.sleep(30)\n")
    monkeypatch.setattr(repro, "DOCKER_TIMEOUT", 2)
    names = []
    original_popen = repro.subprocess.Popen
    def track(args, *rest, **kwargs):
        if args[:2] == ["docker", "run"]:
            names.append(args[args.index("--name") + 1])
        return original_popen(args, *rest, **kwargs)
    monkeypatch.setattr(repro.subprocess, "Popen", track)
    started = time.monotonic()
    code, output, error = repro._docker_run(tmp_path)
    assert code is None and "timed out" in error
    assert time.monotonic() - started < 10
    assert len(names) == 1
    remaining = repro.subprocess.run(["docker", "ps", "-aq", "--filter", f"name=^{names[0]}$"],
                                     capture_output=True, text=True, timeout=5)
    assert not remaining.stdout.strip()
