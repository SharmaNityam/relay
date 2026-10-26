import json
import sqlite3
from pathlib import Path

from relay.adapters import collect_sessions, scan_claude, scan_codex


def _line(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(value) + "\n")


def test_codex_jsonl_extracts_initial_task_status_and_parent(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/26/one.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "child-123456", "cwd": "/work/api",
          "source": {"type": "subagent", "thread_spawn": {"parent_thread_id": "parent-id"}}}})
    _line(path, {"type": "event_msg", "timestamp": "2026-10-26T09:00:00Z", "payload": {
          "type": "user_message", "message": "Fix the API timeout"}})
    _line(path, {"type": "event_msg", "timestamp": "2026-10-26T09:01:00Z", "payload": {"type": "task_started"}})
    _line(path, {"type": "event_msg", "timestamp": "2026-10-26T09:02:00Z", "payload": {"type": "task_complete"}})
    result = scan_codex(home, 10)
    assert len(result) == 1
    assert result[0].id == "child-123456"
    assert result[0].parent_id == "parent-id"
    assert result[0].status == "completed"
    assert result[0].task == "Fix the API timeout"
    assert "api" in result[0].suggested_name.lower()


def test_latest_request_updates_task_but_name_keeps_initial_purpose(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/26/updates.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "updates", "cwd": "/work/api"}})
    _line(path, {"type": "event_msg", "timestamp": "2026-10-26T09:00:00Z", "payload": {
          "type": "user_message", "message": "<environment_context>cwd=/tmp</environment_context> Build the API"}})
    _line(path, {"type": "event_msg", "timestamp": "2026-10-26T09:01:00Z", "payload": {"type": "task_complete"}})
    _line(path, {"type": "event_msg", "timestamp": "2026-10-26T09:02:00Z", "payload": {
          "type": "user_message", "message": "Add pagination"}})
    session = scan_codex(home, 10)[0]
    assert session.task == "Add pagination"
    assert session.status == "unknown"
    assert session.status_source == "observed_user_request"
    assert "Build the API" in session.suggested_name


def test_codex_real_rollout_user_response_shape_after_large_metadata(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/26/agent.jsonl"
    _line(path, {"type": "session_meta", "payload": {
        "id": "agent-thread", "cwd": "/work/service", "agent_path": "/agents/relay_adapters",
        "parent_thread_id": "parent-thread", "padding": "x" * 70000}})
    _line(path, {"type": "response_item", "timestamp": "2026-10-26T09:00:00Z", "payload": {
        "type": "message", "role": "developer", "content": [{"type": "input_text", "text": "do not expose"}]}})
    _line(path, {"type": "response_item", "timestamp": "2026-10-26T09:01:00Z", "payload": {
        "type": "message", "role": "user", "content": [{"type": "input_text", "text": "Repair the request parser"}]}})
    session = scan_codex(home, 10)[0]
    assert session.task == "Repair the request parser"
    assert session.parent_id == "parent-thread"
    assert session.role == "relay_adapters"
    assert "Repair the request parser" in session.suggested_name
    assert "do not expose" not in session.task


def test_codex_agent_path_provides_deterministic_fallback_without_placeholder_title(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/26/agent.jsonl"
    _line(path, {"type": "session_meta", "payload": {
        "id": "agent-thread", "cwd": "/work/service", "agent_path": "/agents/review_service"}})
    session = scan_codex(home, 10)[0]
    assert session.role == "review_service"
    assert session.suggested_name == "service · review_service"


def test_codex_read_only_database_schema_and_unsupported_fallback(tmp_path):
    home = tmp_path / "codex"
    home.mkdir()
    db = home / "state_5.sqlite"
    with sqlite3.connect(db) as con:
        con.execute("CREATE TABLE threads(id TEXT, title TEXT, cwd TEXT, updated_at TEXT, tokens_used INTEGER)")
        con.execute("INSERT INTO threads VALUES(?,?,?,?,?)", ("db-id", "Repair tests", "/work/repo", "2026-10-26T09:00:00Z", 42))
    before = db.read_bytes()
    result = scan_codex(home, 10)
    assert [(s.id, s.tokens) for s in result] == [("db-id", 42)]
    assert db.read_bytes() == before
    bad = tmp_path / "bad"
    bad.mkdir()
    with sqlite3.connect(bad / "state_5.sqlite") as con:
        con.execute("CREATE TABLE unrelated(id TEXT)")
    assert scan_codex(bad, 10) == []


def test_claude_messages_tool_names_tokens_and_nested_agent(tmp_path):
    home = tmp_path / "claude"
    parent = "aaaaaaaa-aaaa"
    path = home / "projects/p" / f"{parent}/subagents/agent-bbbb.jsonl"
    _line(path, {"type": "user", "sessionId": "bbbb", "cwd": "/repo/service", "timestamp": "2026-10-26T09:00:00Z",
                 "message": {"content": [{"type": "text", "text": "Implement health endpoint"}]}})
    _line(path, {"type": "assistant", "timestamp": "2026-10-26T09:01:00Z", "message": {
                 "id": "m1", "content": [{"type": "tool_use", "id": "call1", "name": "Read", "input": {"command": "SECRET"}}],
                 "usage": {"input_tokens": 10, "output_tokens": 3}}})
    _line(path, {"type": "assistant", "timestamp": "2026-10-26T09:02:00Z", "message": {
                 "id": "m1", "content": [{"type": "tool_use", "id": "call1", "name": "Read"}],
                 "usage": {"input_tokens": 10, "output_tokens": 3}}})
    result = scan_claude(home, 10)
    assert len(result) == 1
    assert result[0].parent_id == parent
    assert result[0].role == "Agent"
    assert result[0].task == "Implement health endpoint"
    assert result[0].status == "stale"
    assert result[0].status_source == "inferred_from_outstanding_event_age"
    assert result[0].tokens == 13
    assert "Read" in result[0].last_activity


def test_malformed_truncated_file_and_provider_isolation(tmp_path):
    codex = tmp_path / "codex"
    path = codex / "sessions/2026/10/26/malformed.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "valid", "cwd": "/x"}})
    with path.open("ab") as file:
        file.write(b'{"type":"event_msg","payload":')
    claude = tmp_path / "missing-claude"
    snapshot = collect_sessions(codex, claude, 4)
    assert [s.id for s in snapshot.sessions] == ["valid"]
    assert snapshot.providers[0]["status"] == "ready"
    assert snapshot.providers[1]["status"] == "unavailable"


def test_secret_and_tool_arguments_are_not_exposed(tmp_path):
    home = tmp_path / "claude"
    path = home / "projects/p/session.jsonl"
    _line(path, {"type": "user", "sessionId": "s", "cwd": "/repo", "message": {
        "content": "Deploy with token=supersecretvalue and contact jane@example.com"}})
    _line(path, {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Bash",
                                                                     "input": {"command": "ghp_1234567890SECRET"}}]}})
    s = scan_claude(home, 1)[0]
    assert "supersecretvalue" not in s.task
    assert "jane@example.com" not in s.task
    assert s.last_activity == "Used Bash"
