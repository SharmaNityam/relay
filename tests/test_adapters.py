import json
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

from relay.adapters import _read_bounded, collect_sessions, scan_claude, scan_codex


def _line(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(value) + "\n")


def _ago(seconds: int) -> str:
    """Timestamp relative to now; negative values are in the future."""
    stamp = datetime.now(timezone.utc) - timedelta(seconds=seconds)
    return stamp.isoformat(timespec="seconds").replace("+00:00", "Z")


def _call(name: str, at: str | None, **extra) -> dict:
    record = {"type": "response_item", "payload": {"type": "function_call", "name": name, "status": "completed", **extra}}
    if at is not None:
        record["timestamp"] = at
    return record


def _message(role: str, channel: str | None, at: str | None) -> dict:
    payload = {"type": "message", "role": role, "content": [{"type": "output_text", "text": "SECRET_BODY_CANARY"}]}
    if channel:
        payload["channel"] = channel
    record = {"type": "response_item", "payload": payload}
    if at is not None:
        record["timestamp"] = at
    return record


def _user(text: str, at: str) -> dict:
    return {"type": "event_msg", "timestamp": at, "payload": {"type": "user_message", "message": text}}


def _item(item_type: str, at: str | None, **extra) -> dict:
    record = {"type": "event_msg", "payload": {"type": "item_completed", "item": {"type": item_type, **extra}}}
    if at is not None:
        record["timestamp"] = at
    return record


def _codex_session(home: Path, name: str):
    return {s.id: s for s in scan_codex(home, 20)}[name]


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


def test_local_cli_metadata_is_not_a_task_name(tmp_path):
    home = tmp_path / "claude"
    path = home / "projects/demo/session.jsonl"
    for message in ["<local-command-caveat>The command below was run directly in Claude Code</local-command-caveat><command-name>/login</command-name>", "[Image: source: /tmp/screenshot.png]", "Fix the cache invalidation bug"]:
        _line(path, {"type": "user", "sessionId": "session", "cwd": "/work/cache", "message": {"content": message}})
    session = scan_claude(home, 10)[0]
    assert "Fix the cache invalidation bug" in session.suggested_name
    assert "login" not in session.suggested_name


def test_recent_tool_call_is_running_when_task_started_is_outside_the_read_window(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/27/live.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "live", "cwd": "/work/api"}})
    # Pushes task_started beyond the head window and before the tail window.
    _line(path, {"type": "event_msg", "payload": {"type": "filler", "padding": "x" * 600_000}})
    _line(path, {"type": "event_msg", "timestamp": _ago(300), "payload": {"type": "task_started"}})
    _line(path, {"type": "event_msg", "payload": {"type": "filler", "padding": "y" * 400_000}})
    _line(path, _user("Check the deploy", _ago(20)))
    _line(path, _call("exec_command", _ago(10), arguments='{"command":"ARGS_CANARY_123"}'))
    head, tail = _read_bounded(path)
    assert all(obj.get("payload", {}).get("type") != "task_started" for obj in head + tail)
    session = _codex_session(home, "live")
    assert session.status == "running"
    assert session.status_source == "observed_tool_call"
    assert session.task == "Check the deploy"
    assert session.last_activity == "Used exec_command"
    assert "ARGS_CANARY_123" not in json.dumps(vars(session), default=str)


def test_completed_tool_item_refreshes_running_but_never_completes_session(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/27/tool.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "tool", "cwd": "/work/api"}})
    _line(path, _user("Run the tests", _ago(60)))
    _line(path, _call("exec_command", _ago(50)))
    _line(path, _item("CommandExecution", _ago(5), command="pytest OUTPUT_CANARY_1", aggregated_output="OUTPUT_CANARY_1"))
    session = _codex_session(home, "tool")
    assert session.status == "running"
    assert session.status_source == "observed_tool_call"
    assert session.last_activity == "Used CommandExecution"
    assert "OUTPUT_CANARY_1" not in json.dumps(vars(session), default=str)


def test_tool_item_without_assistant_call_does_not_start_running(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/27/item.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "item", "cwd": "/work/api"}})
    _line(path, _user("Look it up", _ago(30)))
    _line(path, _item("McpToolCall", _ago(5), name="search"))
    session = _codex_session(home, "item")
    assert session.status == "unknown"
    assert session.status_source == "observed_user_request"
    assert session.last_activity == "Used search"


def test_final_assistant_message_completes_and_later_usage_keeps_it(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/27/final.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "final", "cwd": "/work/api"}})
    _line(path, _user("Fix the parser", _ago(60)))
    _line(path, _call("exec_command", _ago(50)))
    _line(path, _message("assistant", "commentary", _ago(30)))
    _line(path, _message("assistant", "final", _ago(20)))
    _line(path, {"type": "event_msg", "timestamp": _ago(10), "payload": {
        "type": "token_count", "info": {"total_token_usage": {"total_tokens": 77}}}})
    session = _codex_session(home, "final")
    assert session.status == "completed"
    assert session.status_source == "observed_assistant_final"
    assert session.tokens == 77
    assert "SECRET_BODY_CANARY" not in json.dumps(vars(session), default=str)


def test_usage_after_aborted_turn_keeps_interrupted_state(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/27/aborted.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "aborted", "cwd": "/work/api"}})
    _line(path, _user("Run the migration", _ago(40)))
    _line(path, _call("exec_command", _ago(30)))
    _line(path, {"type": "event_msg", "timestamp": _ago(20), "payload": {"type": "turn_aborted"}})
    _line(path, {"type": "event_msg", "timestamp": _ago(5), "payload": {
        "type": "token_count", "info": {"total_token_usage": {"total_tokens": 5}}}})
    session = _codex_session(home, "aborted")
    assert session.status == "interrupted"
    assert session.status_source == "observed_task_aborted"
    assert session.tokens == 5


def test_reasoning_refreshes_running_state_but_never_starts_it(tmp_path):
    home = tmp_path / "codex"
    progress = home / "sessions/2026/10/27/progress.jsonl"
    _line(progress, {"type": "session_meta", "payload": {"id": "progress", "cwd": "/work/api"}})
    _line(progress, _user("Long job", _ago(400)))
    _line(progress, _call("exec_command", _ago(200)))
    _line(progress, {"type": "response_item", "timestamp": _ago(5), "payload": {
        "type": "reasoning", "encrypted_content": "REASONING_CANARY_9"}})
    idle = home / "sessions/2026/10/27/idle.jsonl"
    _line(idle, {"type": "session_meta", "payload": {"id": "idle", "cwd": "/work/api"}})
    _line(idle, _user("Just thinking", _ago(30)))
    _line(idle, {"type": "response_item", "timestamp": _ago(5), "payload": {"type": "reasoning"}})
    refreshed = _codex_session(home, "progress")
    assert refreshed.status == "running"
    assert refreshed.status_source == "observed_tool_call"
    unchanged = _codex_session(home, "idle")
    assert unchanged.status == "unknown"
    assert unchanged.status_source == "observed_user_request"
    assert "REASONING_CANARY_9" not in json.dumps(vars(refreshed), default=str)


def test_stale_missing_invalid_and_future_tool_timestamps_never_mark_running(tmp_path):
    home = tmp_path / "codex"
    cases = [("stale", _ago(300), "stale"), ("missing", None, "unknown"),
             ("invalid", "soon", "unknown"), ("future", _ago(-3600), "unknown")]
    for name, at, _ in cases:
        path = home / "sessions/2026/10/27" / f"{name}.jsonl"
        _line(path, {"type": "session_meta", "payload": {"id": name, "cwd": "/work/api"}})
        _line(path, _user("Check status", _ago(30)))
        _line(path, _call("exec_command", at))
    result = {s.id: s for s in scan_codex(home, 20)}
    for name, _, expected in cases:
        assert result[name].status == expected, name
        assert result[name].status != "running", name
    assert result["stale"].status_source == "inferred_from_outstanding_event_age"
    assert result["missing"].status_source == "observed_user_request"
    assert result["future"].status_source == "observed_user_request"


def test_tool_inputs_outputs_and_reasoning_bodies_never_appear(tmp_path):
    home = tmp_path / "codex"
    path = home / "sessions/2026/10/27/canary.jsonl"
    _line(path, {"type": "session_meta", "payload": {"id": "canary", "cwd": "/work/api"}})
    _line(path, _user("Summarize the logs", _ago(60)))
    _line(path, _call("exec_command", _ago(50), arguments='{"command":"ARGS_CANARY_2"}'))
    _line(path, {"type": "response_item", "timestamp": _ago(45), "payload": {
        "type": "custom_tool_call", "name": "apply_patch", "status": "completed", "input": "INPUT_CANARY_2"}})
    _line(path, {"type": "response_item", "timestamp": _ago(40), "payload": {
        "type": "reasoning", "encrypted_content": "REASONING_CANARY_2"}})
    _line(path, _item("CommandExecution", _ago(20), command="OUTPUT_CANARY_2", aggregated_output="OUTPUT_CANARY_2"))
    _line(path, _message("assistant", "final", _ago(10)))
    session = _codex_session(home, "canary")
    dumped = json.dumps(vars(session), default=str)
    for canary in ("ARGS_CANARY_2", "INPUT_CANARY_2", "REASONING_CANARY_2", "OUTPUT_CANARY_2", "SECRET_BODY_CANARY"):
        assert canary not in dumped
    assert session.status == "completed"
    assert session.status_source == "observed_assistant_final"
