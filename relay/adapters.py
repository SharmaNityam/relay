"""Read-only, bounded Codex and Claude Code session metadata adapters."""
from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import time
from datetime import datetime, timezone
from itertools import islice
from pathlib import Path
from typing import Any

from .contracts import Session, Snapshot
from .naming import clean_text, suggest_name

_HEAD_BYTES = 512 * 1024
_TAIL_BYTES = 256 * 1024
_MAX_JSONL_LINE = 256 * 1024
_MAX_ENTRIES_PER_DIRECTORY = 512
_MAX_JSONL_DISCOVERY = 2000
_STALE_SECONDS = 120
_MAX_CLAUDE_DISCOVERY = 5000
_MAX_CLAUDE_PROJECTS = 128
_MAX_ITEMS_PER_PROJECT = 32


def _valid_token_count(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value) or value < 0:
        return None
    return int(value)


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    try:
        if isinstance(value, (int, float)):
            # SQLite timestamps may be epoch seconds or milliseconds.
            stamp = float(value)
            if stamp > 10**12:
                stamp /= 1000
            dt = datetime.fromtimestamp(stamp, timezone.utc)
        else:
            text = str(value).strip()
            if not text:
                return None
            if text.isdigit():
                return _iso(int(text))
            dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            dt = dt.astimezone(timezone.utc)
        return dt.isoformat(timespec="seconds").replace("+00:00", "Z")
    except (ValueError, TypeError, OSError, OverflowError):
        return None


def _epoch(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _read_bounded(path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Parse only a small prefix and suffix; malformed/truncated records are ignored."""
    try:
        with path.open("rb") as f:
            size = os.fstat(f.fileno()).st_size
            head = f.read(min(size, _HEAD_BYTES))
            tail = b""
            if size > _HEAD_BYTES:
                f.seek(max(_HEAD_BYTES, size - _TAIL_BYTES))
                tail = f.read(_TAIL_BYTES)
    except OSError:
        return [], []
    def decode(chunk: bytes) -> list[dict[str, Any]]:
        output = []
        for line in chunk.splitlines():
            if len(line) > _MAX_JSONL_LINE:
                continue
            try:
                obj = json.loads(line)
                if isinstance(obj, dict):
                    output.append(obj)
            except (ValueError, UnicodeDecodeError):
                continue
        return output
    return decode(head), decode(tail)


def _extract_user_text(value: Any) -> str:
    if isinstance(value, str):
        return clean_text(value, 400)
    if isinstance(value, dict):
        return _extract_user_text(value.get("content") or value.get("text") or value.get("message"))
    if isinstance(value, list):
        parts = []
        for part in value:
            if isinstance(part, dict) and part.get("type") in ("text", "input_text"):
                if isinstance(part.get("text"), str):
                    parts.append(part["text"])
        return clean_text(" ".join(parts), 400)
    return ""


def _codex_response_user_text(payload: dict[str, Any]) -> str:
    if payload.get("type") != "message" or payload.get("role") != "user":
        return ""
    return _extract_user_text(payload.get("content"))


def _project(cwd: str) -> str:
    if not cwd:
        return "Unknown project"
    return Path(cwd.rstrip("/\\")).name or cwd


def _status(status: str, source: str, at: str | None) -> tuple[str, str]:
    epoch = _epoch(at)
    now = time.time()
    if status in ("running", "waiting") and epoch is None:
        return "unknown", "invalid_timestamp_for_outstanding_event"
    if epoch is not None and epoch > now + 60:
        return "unknown", "invalid_future_timestamp_for_activity"
    if status in ("running", "waiting") and epoch is not None and now - epoch > _STALE_SECONDS:
        return "stale", "inferred_from_outstanding_event_age"
    return status, source


def _usable_at(at: str | None) -> bool:
    """A missing, unparsable, or future timestamp cannot show that work is outstanding."""
    epoch = _epoch(at)
    return epoch is not None and epoch <= time.time() + 60


def _refreshed_at(status: str, at: str | None, state_at: str | None) -> str | None:
    """Assistant progress can keep a running state fresh, but never starts one."""
    return at if status == "running" and _usable_at(at) else state_at


def _safe_source_path(root: Path, candidate: Path) -> bool:
    """Only accept a known session path with no symlink in any path component."""
    try:
        root_abs = root.absolute()
        candidate_abs = candidate.absolute()
        relative = candidate_abs.relative_to(root_abs)
        current = root_abs
        if current.is_symlink():
            return False
        for part in relative.parts:
            current = current / part
            if current.is_symlink():
                return False
        return candidate_abs.resolve(strict=True).is_relative_to(root_abs.resolve(strict=True))
    except (OSError, ValueError, RuntimeError):
        return False


def _codex_events(events: list[dict[str, Any]], initial: str = "") -> dict[str, Any]:
    task = initial
    status, status_source, activity, last_at = "unknown", "unknown", "No observed activity", None
    state_at: str | None = None
    tokens = None
    model = None
    for obj in events:
        typ = obj.get("type")
        payload = obj.get("payload") if isinstance(obj.get("payload"), dict) else {}
        at = _iso(obj.get("timestamp") or obj.get("created_at") or payload.get("timestamp"))
        if at:
            last_at = at
        if typ == "session_meta":
            model = clean_text(str(payload.get("model") or ""), 80) or model
        elif typ == "event_msg":
            kind = payload.get("type")
            if kind == "task_started":
                status, status_source, activity = "running", "observed_task_started", "Task started"
                state_at = at
            elif kind in ("task_complete", "turn_complete"):
                status, status_source, activity = "completed", "observed_task_complete", "Task completed"
                state_at = at
            elif kind in ("turn_aborted", "task_aborted"):
                status, status_source, activity = "interrupted", "observed_task_aborted", "Task interrupted"
                state_at = at
            elif kind in ("token_count", "token_usage_record"):
                info = payload.get("info") if isinstance(payload.get("info"), dict) else payload
                usage = info.get("total_token_usage") or info.get("token_usage") or info
                if isinstance(usage, dict):
                    n = usage.get("total_tokens")
                    if n is None:
                        n = usage.get("total")
                    parsed = _valid_token_count(n)
                    if parsed is not None:
                        tokens = parsed
            elif kind == "user_message":
                msg = _extract_user_text(payload.get("message") or payload.get("content"))
                if msg:
                    task = msg
                    status, status_source, activity = "unknown", "observed_user_request", "New user request observed"
                    state_at = at
            elif kind == "item_completed":
                # Completed tool items show recent activity only; they never mark the session completed.
                item = payload.get("item") if isinstance(payload.get("item"), dict) else {}
                item_type = item.get("type")
                if item_type == "Reasoning":
                    state_at = _refreshed_at(status, at, state_at)
                elif item_type in ("CommandExecution", "McpToolCall"):
                    label = clean_text(str(item.get("name") or item_type), 48)
                    activity = f"Used {label}"
                    state_at = _refreshed_at(status, at, state_at)
        elif typ == "response_item":
            kind = payload.get("type")
            if kind == "message":
                msg = _codex_response_user_text(payload)
                if msg:
                    task = msg
                    status, status_source, activity = "unknown", "observed_user_request", "New user request observed"
                    state_at = at
                elif payload.get("role") == "assistant" and payload.get("channel") == "final":
                    # Only the channel marker is read; the message body is never inspected.
                    status, status_source, activity = "completed", "observed_assistant_final", "Assistant final message"
                    state_at = at
                elif payload.get("role") == "assistant" and payload.get("channel") == "commentary":
                    state_at = _refreshed_at(status, at, state_at)
            elif kind == "reasoning":
                state_at = _refreshed_at(status, at, state_at)
            elif kind in ("function_call", "custom_tool_call"):
                # Only the function/tool name is useful activity metadata. Never inspect args.
                name = clean_text(str(payload.get("name") or payload.get("tool_name") or "tool"), 48)
                activity = f"Used {name}"
                if _usable_at(at):
                    status, status_source, state_at = "running", "observed_tool_call", at
        elif typ in ("token_usage_record", "token_count"):
            usage = payload.get("total_token_usage") or payload.get("token_usage") or payload
            if isinstance(usage, dict):
                n = usage.get("total_tokens")
                if n is None:
                    n = usage.get("total")
                parsed = _valid_token_count(n)
                if parsed is not None:
                    tokens = parsed
    if status == "unknown" and last_at:
        # An event timestamp alone is not evidence that work is still running.
        activity = activity if activity != "No observed activity" else "Session activity observed"
    status, status_source = _status(status, status_source, state_at)
    return {"task": task, "status": status, "status_source": status_source,
            "last_event_at": last_at, "last_activity": activity, "tokens": tokens, "model": model}


def _session_from_codex_row(row: dict[str, Any], parents: dict[str, str]) -> Session | None:
    session_id = clean_text(str(row.get("id") or ""), 128)
    if not session_id:
        return None
    cwd = clean_text(str(row.get("cwd") or ""), 512)
    title = clean_text(str(row.get("title") or ""), 160) or "Untitled session"
    task = clean_text(str(row.get("first_user_message") or ""), 400)
    role_value = row.get("agent_role")
    if not role_value and row.get("agent_path"):
        role_value = Path(str(row["agent_path"]).rstrip("/\\")).name
    role = clean_text(str(role_value or "main"), 64)
    parent = parents.get(session_id)
    updated = _iso(row.get("updated_at") or row.get("created_at"))
    # Archived is a UI/library flag, not evidence that the task completed.
    raw_status = "unknown"
    source = "database_timestamp_only" if updated else "unknown"
    status, source = _status(raw_status, source, updated)
    s = Session(provider="codex", id=session_id, title=title, task=task, cwd=cwd,
                project=_project(cwd), parent_id=parent,
                role=role, model=clean_text(str(row.get("model") or ""), 80) or None,
                status=status, status_source=source, last_event_at=updated,
                last_activity="Session metadata updated" if updated else "No observed activity",
                tokens=_valid_token_count(row.get("tokens_used")))
    s.suggested_name = suggest_name(s)
    return s


def _db_rows(db: Path, limit: int, home: Path | None = None) -> tuple[list[Session], bool]:
    """Return sessions and whether the database has a recognized threads schema."""
    uri = f"file:{db.as_posix()}?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=0.25)
    con.row_factory = sqlite3.Row
    try:
        con.execute("PRAGMA query_only=ON")
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "threads" not in tables:
            return [], False
        cols = {r[1] for r in con.execute("PRAGMA table_info(threads)")}
        if "id" not in cols:
            return [], False
        allowed = ["id", "rollout_path", "title", "first_user_message", "cwd", "agent_nickname",
                   "agent_role", "agent_path", "model", "updated_at", "created_at", "tokens_used",
                   "archived", "source"]
        selected = [c for c in allowed if c in cols]
        order_col = "updated_at" if "updated_at" in cols else ("created_at" if "created_at" in cols else "id")
        rows = [dict(r) for r in con.execute(
            f"SELECT {', '.join(selected)} FROM threads ORDER BY {order_col} DESC LIMIT ?", (limit,))]
        parents: dict[str, str] = {}
        if "thread_spawn_edges" in tables:
            edge_cols = {r[1] for r in con.execute("PRAGMA table_info(thread_spawn_edges)")}
            child_col = next((c for c in ("child_thread_id", "agent_thread_id", "child_id") if c in edge_cols), None)
            parent_col = next((c for c in ("parent_thread_id", "thread_id", "parent_id") if c in edge_cols), None)
            row_ids = [r.get("id") for r in rows if r.get("id")]
            if child_col and parent_col and row_ids:
                for offset in range(0, len(row_ids), 500):
                    chunk = row_ids[offset:offset + 500]
                    placeholders = ",".join("?" for _ in chunk)
                    parents.update({str(r[0]): str(r[1]) for r in con.execute(
                        f"SELECT {child_col}, {parent_col} FROM thread_spawn_edges WHERE {child_col} IN ({placeholders})",
                        chunk)})
        output: list[Session] = []
        session_root = (home or db.parent) / "sessions"
        for row in rows:
            session = _session_from_codex_row(row, parents)
            if session is None:
                continue
            rollout = row.get("rollout_path")
            if isinstance(rollout, str) and rollout:
                rollout_path = Path(rollout)
                if not rollout_path.is_absolute():
                    rollout_path = db.parent / rollout_path
                if _safe_source_path(session_root, rollout_path):
                    evidence, _ = _codex_file(rollout_path)
                    if evidence and evidence.id == session.id:
                        initial_task = session.task
                        session.task = evidence.task or session.task
                        session.status = evidence.status
                        session.status_source = evidence.status_source
                        session.last_event_at = evidence.last_event_at or session.last_event_at
                        session.last_activity = evidence.last_activity
                        session.tokens = evidence.tokens if evidence.tokens is not None else session.tokens
                        session.model = session.model or evidence.model
                        session.parent_id = session.parent_id or evidence.parent_id
                        # The visible task follows the latest user message; the suggested name
                        # remains grounded in the initial task from the database when available.
                        name_session = Session(**{**session.__dict__, "task": initial_task or session.task})
                        session.suggested_name = suggest_name(name_session)
            output.append(session)
        return output, True
    finally:
        con.close()


def _codex_json_files(home: Path, limit: int) -> list[Path]:
    if limit <= 0:
        return []
    root = home / "sessions"
    found: list[Path] = []
    try:
        if not root.is_dir() or not _safe_source_path(home, root):
            return []
        # Fixed-depth known directory layout (year/month/day); avoid unrestricted recursive scans.
        for year in sorted(islice(root.iterdir(), _MAX_ENTRIES_PER_DIRECTORY), reverse=True):
            if not year.is_dir() or not _safe_source_path(home, year):
                continue
            for month in sorted(islice(year.iterdir(), _MAX_ENTRIES_PER_DIRECTORY), reverse=True):
                if not month.is_dir() or not _safe_source_path(home, month):
                    continue
                for day in sorted(islice(month.iterdir(), _MAX_ENTRIES_PER_DIRECTORY), reverse=True):
                    if not day.is_dir() or not _safe_source_path(home, day):
                        continue
                    paths = islice(day.glob("*.jsonl"), _MAX_JSONL_DISCOVERY)
                    for path in sorted(paths, key=lambda p: p.lstat().st_mtime, reverse=True):
                        if path.is_file() and _safe_source_path(home, path):
                            found.append(path)
                            if len(found) >= limit:
                                return found
    except OSError:
        return found
    return found


def _codex_file(path: Path) -> tuple[Session | None, list[str]]:
    head, tail = _read_bounded(path)
    events = head + [obj for obj in tail if obj not in head]
    meta: dict[str, Any] = {}
    task = ""
    parent = None
    for obj in head:
        typ, payload = obj.get("type"), obj.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        if typ == "session_meta":
            meta = payload
            if isinstance(payload.get("source"), dict):
                source = payload["source"]
                # Codex has emitted both a typed source envelope and a direct subagent object.
                nested = source.get("subagent") if isinstance(source.get("subagent"), dict) else source
                spawn = nested.get("thread_spawn") if isinstance(nested, dict) else None
                if isinstance(spawn, dict):
                    parent = spawn.get("parent_thread_id")
            if not parent:
                parent = payload.get("parent_thread_id")
        elif typ == "event_msg" and payload.get("type") == "user_message" and not task:
            task = _extract_user_text(payload.get("message") or payload.get("content"))
        elif typ == "response_item" and not task:
            task = _codex_response_user_text(payload)
    session_id = clean_text(str(meta.get("id") or ""), 128)
    if not session_id:
        return None, []
    state = _codex_events(events, task)
    cwd = clean_text(str(meta.get("cwd") or ""), 512)
    role_value = meta.get("agent_role")
    if not role_value and meta.get("agent_path"):
        role_value = Path(str(meta["agent_path"]).rstrip("/\\")).name
    role = clean_text(str(role_value or ("subagent" if parent else "main")), 64)
    s = Session(provider="codex", id=session_id, title="Untitled session", task=state["task"], cwd=cwd,
                project=_project(cwd), parent_id=clean_text(str(parent), 128) if parent else None,
                role=role, model=state["model"], status=state["status"], status_source=state["status_source"],
                last_event_at=state["last_event_at"], last_activity=state["last_activity"], tokens=state["tokens"])
    name_session = Session(**{**s.__dict__, "task": task or state["task"]})
    s.suggested_name = suggest_name(name_session)
    return s, [session_id]


def scan_codex(home: Path, limit: int) -> list[Session]:
    home = Path(home).expanduser()
    limit = max(0, min(int(limit), 10000))
    if not limit:
        return []
    for db in (home / "state_5.sqlite", home / "sqlite" / "state_5.sqlite"):
        if db.is_file():
            try:
                if db.is_symlink() or not _safe_source_path(home, db):
                    continue
                rows, recognized = _db_rows(db, limit, home)
                if recognized and rows:
                    return rows[:limit]
            except (sqlite3.Error, OSError, ValueError):
                continue
    output: list[Session] = []
    for path in _codex_json_files(home, limit):
        session, _ = _codex_file(path)
        if session:
            output.append(session)
            if len(output) >= limit:
                break
    return output


def _claude_message_text(content: Any) -> tuple[str, list[tuple[str, str]]]:
    texts: list[str] = []
    tools: list[tuple[str, str]] = []
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                texts.append(part["text"])
            elif part.get("type") == "tool_use":
                tools.append((clean_text(str(part.get("name") or "tool"), 48),
                              clean_text(str(part.get("id") or ""), 128)))
    return clean_text(" ".join(texts), 400), tools


def _claude_session(path: Path, parent_id: str | None = None, child_role: str | None = None) -> Session | None:
    head, tail = _read_bounded(path)
    entries = head + [obj for obj in tail if obj not in head]
    session_id = ""
    cwd = ""
    initial_task = ""
    latest_task = ""
    status, source, activity, last_at = "unknown", "unknown", "No observed activity", None
    state_at: str | None = None
    tokens = None
    seen_messages: set[str] = set()
    for obj in entries:
        typ = obj.get("type")
        at = _iso(obj.get("timestamp"))
        if at:
            last_at = at
        if typ == "user" and not session_id:
            session_id = clean_text(str(obj.get("sessionId") or ""), 128)
        if typ == "custom-title":
            pass
        elif typ == "ai-title":
            pass
        elif typ in ("progress", "file-history-snapshot", "queue-operation"):
            continue
        elif typ in ("user", "assistant"):
            msg = obj.get("message") if isinstance(obj.get("message"), dict) else {}
            content, tool_uses = _claude_message_text(msg.get("content"))
            if typ == "user" and content:
                if not initial_task:
                    initial_task = content
                latest_task = content
                status, source, activity = "unknown", "observed_user_request", "New user request observed"
                state_at = at
            if typ == "assistant":
                msgid = str(msg.get("id") or obj.get("uuid") or "")
                if msgid and msgid not in seen_messages:
                    seen_messages.add(msgid)
                    usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
                    values = [_valid_token_count(v) for v in (usage.get("input_tokens"), usage.get("output_tokens"),
                                                               usage.get("cache_read_input_tokens"), usage.get("cache_creation_input_tokens"))]
                    reported = [v for v in values if v is not None]
                    if reported:
                        tokens = (tokens or 0) + sum(reported)
                if tool_uses:
                    activity = f"Used {tool_uses[-1][0]}"
                    status, source = "running", "observed_assistant_tool_use"
                    state_at = at
                elif msg.get("stop_reason") == "end_turn":
                    status, source, activity = "completed", "observed_end_turn", "Assistant turn completed"
                    state_at = at
        if typ == "user" and isinstance(obj.get("cwd"), str) and not cwd:
            cwd = clean_text(obj["cwd"], 512)
    if parent_id and path.stem.startswith("agent-"):
        session_id = path.stem[len("agent-"):]
    elif not session_id:
        # A Claude transcript's UUID is ordinarily its filename stem; it is a known source identifier.
        session_id = path.stem
    status, source = _status(status, source, state_at)
    title = "Untitled session"
    # Claude title metadata is user-visible naming metadata; keep it bounded and sanitized.
    for obj in entries:
        if obj.get("type") in ("custom-title", "ai-title"):
            title = clean_text(str(obj.get("customTitle") or obj.get("aiTitle") or obj.get("title") or ""), 160) or title
    role = child_role or "main"
    s = Session(provider="claude", id=session_id, title=title, task=latest_task, cwd=cwd,
                project=_project(cwd), parent_id=parent_id, role=role, model=None, status=status,
                status_source=source, last_event_at=last_at, last_activity=activity, tokens=tokens)
    name_session = Session(**{**s.__dict__, "task": initial_task or latest_task})
    s.suggested_name = suggest_name(name_session)
    return s


def _claude_files(home: Path, limit: int) -> list[tuple[Path, str | None, str | None]]:
    if limit <= 0:
        return []
    root = home / "projects"
    candidates: list[tuple[Path, str | None, str | None]] = []
    try:
        if not _safe_source_path(home, root):
            return []
        projects = sorted((p for p in islice(root.iterdir(), _MAX_ENTRIES_PER_DIRECTORY)
                           if p.is_dir() and _safe_source_path(home, p)),
                          key=lambda p: p.lstat().st_mtime, reverse=True)[:_MAX_CLAUDE_PROJECTS]
        for project in projects:
            direct = sorted(islice(project.glob("*.jsonl"), _MAX_ENTRIES_PER_DIRECTORY),
                            key=lambda p: p.lstat().st_mtime, reverse=True)
            for path in direct[:_MAX_ITEMS_PER_PROJECT]:
                if path.is_file() and _safe_source_path(home, path):
                    candidates.append((path, None, None))
            # One fixed subagent directory level per parent transcript.
            parents = sorted((p for p in islice(project.iterdir(), _MAX_ENTRIES_PER_DIRECTORY)
                              if p.is_dir() and _safe_source_path(home, p)),
                             key=lambda p: p.lstat().st_mtime, reverse=True)[:_MAX_ITEMS_PER_PROJECT]
            for parent in parents:
                parent_id = parent.name
                subdir = parent / "subagents"
                try:
                    if not subdir.is_dir() or not _safe_source_path(home, subdir):
                        continue
                    for child in islice(subdir.glob("agent-*.jsonl"), _MAX_ENTRIES_PER_DIRECTORY):
                        if child.is_file() and _safe_source_path(home, child):
                            candidates.append((child, parent_id, "Agent"))
                            if len(candidates) >= _MAX_CLAUDE_DISCOVERY:
                                break
                except OSError:
                    continue
                if len(candidates) >= _MAX_CLAUDE_DISCOVERY:
                    break
            if len(candidates) >= _MAX_CLAUDE_DISCOVERY:
                break
    except OSError:
        return []
    candidates.sort(key=lambda item: item[0].lstat().st_mtime, reverse=True)
    return candidates[:limit]


def scan_claude(home: Path, limit: int) -> list[Session]:
    home = Path(home).expanduser()
    limit = max(0, min(int(limit), 10000))
    if not limit:
        return []
    output: list[Session] = []
    for path, parent_id, role in _claude_files(home, limit):
        session = _claude_session(path, parent_id, role)
        if session:
            output.append(session)
            if len(output) >= limit:
                break
    return output


def collect_sessions(codex_home: Path | None = None, claude_home: Path | None = None,
                     limit: int = 100) -> Snapshot:
    codex_home = Path(codex_home).expanduser() if codex_home else Path.home() / ".codex"
    if claude_home:
        claude_home = Path(claude_home).expanduser()
    else:
        claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser()
    limit = max(0, min(int(limit), 10000))
    by_provider: dict[str, list[Session]] = {}
    providers: list[dict[str, Any]] = []
    for provider, home, scanner in (("codex", codex_home, scan_codex), ("claude", claude_home, scan_claude)):
        if not home.exists():
            providers.append({"id": provider, "status": "unavailable", "message": "Session directory not found", "count": 0})
            continue
        try:
            found = scanner(home, limit)
            by_provider[provider] = found
            providers.append({"id": provider, "status": "ready", "message": "Session metadata read", "count": 0})
        except (OSError, sqlite3.Error, ValueError) as exc:
            # Keep provider errors isolated; error messages avoid filesystem content.
            providers.append({"id": provider, "status": "error", "message": type(exc).__name__, "count": 0})
    # Interleave recent provider lists so a busy provider cannot consume the whole cap.
    sessions: list[Session] = []
    ready = [p["id"] for p in providers if p["status"] == "ready"]
    for index in range(max((len(by_provider.get(p, [])) for p in ready), default=0)):
        for provider in ready:
            values = by_provider.get(provider, [])
            if index < len(values) and len(sessions) < limit:
                sessions.append(values[index])
    counts: dict[str, int] = {}
    for session in sessions:
        counts[session.provider] = counts.get(session.provider, 0) + 1
    for provider in providers:
        provider["count"] = counts.get(provider["id"], 0)
    return Snapshot(sessions=sessions, providers=providers,
                    updated_at=datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"))
