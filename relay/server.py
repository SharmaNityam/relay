"""Loopback API for Relay session metadata and bounded reproduction jobs."""
from __future__ import annotations

import asyncio
import json
import os
import shutil
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles

from . import __version__
from .adapters import collect_sessions
from .store import Store

STATE_DIR = Path(os.environ.get("RELAY_STATE_DIR", "~/.local/share/relay")).expanduser()
_scan_lock = asyncio.Lock()
_scan_at = 0.0
_scan_value: dict[str, Any] | None = None
_store = Store(STATE_DIR)
_repro = None
_DEMO_PREFIX = "demo-"


@asynccontextmanager
async def _lifespan(_app):
    yield
    if _repro is not None:
        await asyncio.to_thread(_repro.shutdown)


app = FastAPI(title="Relay", docs_url=None, redoc_url=None, openapi_url=None, lifespan=_lifespan)


def _stamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def demo_snapshot() -> dict[str, Any]:
    """Clearly synthetic session metadata; it contains no provider histories."""
    raw = [
        ("demo-codex", "codex", None, "Implement session filters", "running", "Main", "Codex", "Building filter controls"),
        ("demo-codex-child", "codex", "demo-codex", "Review API boundary", "waiting", "Agent", "Codex", "Waiting for parent review"),
        ("demo-claude", "claude", None, "Fix report formatting", "completed", "Main", "Relay", "Task completed"),
        ("demo-claude-child", "claude", "demo-claude", "Add regression coverage", "failed", "Agent", "Relay", "Task failed"),
        ("demo-stale", "codex", None, "Update dependencies", "stale", "Main", "Relay", "Last observed task is stale"),
        ("demo-unknown", "claude", None, "Explore error handling", "unknown", "Main", "Relay", "No current state observed"),
    ]
    sessions = []
    for sid, provider, parent, title, status, role, project, activity in raw:
        sessions.append({
            "provider": provider, "id": sid, "key": f"{provider}:{sid}",
            "parent_id": parent, "parent_key": f"{provider}:{parent}" if parent else None,
            "title": title, "display_name": title, "suggested_name": title,
            "task": title, "cwd": "", "project": project, "role": role,
            "model": "synthetic", "status": status, "status_source": "synthetic_demo",
            "last_event_at": None, "last_activity": activity, "tokens": None,
        })
    counts = {key: sum(s["status"] == key for s in sessions) for key in
              ("running", "waiting", "completed", "failed", "interrupted", "stale", "unknown")}
    return {"sessions": sessions,
            "providers": [{"id": p, "status": "demo", "message": "Synthetic metadata only", "count": 3}
                          for p in ("codex", "claude")],
            "counts": counts, "updated_at": _stamp(), "total": len(sessions), "demo": True}


def _docker_available() -> bool:
    if not shutil.which("docker"):
        return False
    try:
        import subprocess
        result = subprocess.run(["docker", "image", "inspect", "relay-repro:local"],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=2, check=False)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


async def _snapshot() -> dict[str, Any]:
    global _scan_at, _scan_value
    async with _scan_lock:
        now = time.monotonic()
        if _scan_value is None or now - _scan_at >= 3:
            snap = await asyncio.to_thread(collect_sessions, limit=100)
            _scan_value = _store.apply(snap.to_dict())
            _scan_at = time.monotonic()
        return _scan_value


def _host_authority(value: str | None) -> tuple[str, int | None] | None:
    if not value or any(c in value for c in "\r\n/@\\"):
        return None
    from urllib.parse import urlsplit
    try:
        parsed = urlsplit("//" + value)
        if parsed.path or parsed.query or parsed.fragment or parsed.username or parsed.password:
            return None
        host = (parsed.hostname or "").lower()
        port = parsed.port
    except ValueError:
        return None
    if host not in {"127.0.0.1", "localhost", "[::1]", "::1", "testserver"}:
        return None
    return host.strip("[]"), port


@app.middleware("http")
async def local_only(request: Request, call_next):
    host = request.headers.get("host")
    authority = _host_authority(host)
    if authority is None:
        return JSONResponse({"detail": "Invalid Host"}, status_code=400)
    fetch_site = request.headers.get("sec-fetch-site", "").lower()
    public_navigation = (request.method == "GET" and not request.url.path.startswith("/api/")
                        and request.headers.get("sec-fetch-mode", "").lower() == "navigate"
                        and request.headers.get("sec-fetch-dest", "").lower() == "document")
    if fetch_site in ("cross-site", "none") and not public_navigation:
        return JSONResponse({"detail": "Cross-site request rejected"}, status_code=403)
    origin = request.headers.get("origin")
    if origin:
        from urllib.parse import urlsplit
        try:
            parsed = urlsplit(origin)
            origin_auth = _host_authority(parsed.netloc)
            scheme_ok = parsed.scheme == request.url.scheme
            origin_port = origin_auth[1] if origin_auth else None
            host_port = authority[1] if authority else None
            if origin_port is None:
                origin_port = 443 if parsed.scheme == "https" else 80
            if host_port is None:
                host_port = 443 if request.url.scheme == "https" else 80
            same = bool(origin_auth and authority and origin_auth[0] == authority[0]
                        and origin_port == host_port)
            if (not public_navigation and
                    (not scheme_ok or parsed.path not in ("", "/") or parsed.query or parsed.fragment or not same)):
                raise ValueError
        except (ValueError, TypeError):
            return JSONResponse({"detail": "Invalid Origin"}, status_code=403)
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["Content-Security-Policy"] = "frame-ancestors 'none'"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


async def _json_body(request: Request) -> dict[str, Any]:
    if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
        raise ValueError("Content-Type must be application/json")
    length = request.headers.get("content-length")
    if length:
        try:
            if int(length) > 65536:
                raise OverflowError
        except ValueError:
            raise ValueError("Invalid Content-Length")
        except OverflowError:
            raise ValueError("Request body too large")
    chunks, total = [], 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > 65536:
            raise ValueError("Request body too large")
        chunks.append(chunk)
    try:
        value = json.loads(b"".join(chunks))
    except (ValueError, UnicodeDecodeError):
        raise ValueError("Invalid JSON")
    if not isinstance(value, dict):
        raise ValueError("JSON object required")
    return value


def _known(provider: str, sid: str, snap: dict[str, Any]) -> bool:
    if provider not in ("codex", "claude"):
        return False
    if any(s.get("provider") == provider and s.get("id") == sid for s in snap.get("sessions", [])):
        return True
    return bool(sid.startswith(_DEMO_PREFIX) and any(s.get("provider") == provider and s.get("id") == sid
                                                       for s in demo_snapshot()["sessions"]))


@app.get("/api/health")
async def health():
    snap = await _snapshot()
    return {"status": "ok", "version": __version__, "docker_available": _docker_available(),
            "providers": snap.get("providers", [])}


@app.get("/api/sessions")
async def sessions(demo: str | None = None):
    if demo == "1":
        return _store.apply(demo_snapshot())
    return await _snapshot()


@app.patch("/api/sessions/{provider}/{sid}/name")
async def set_name(provider: str, sid: str, request: Request):
    global _scan_value
    try:
        body = await _json_body(request)
    except ValueError as e:
        return JSONResponse({"detail": str(e)}, status_code=400)
    name = body.get("name")
    if not isinstance(name, str) or len(name) > 120:
        return JSONResponse({"detail": "name must be a string of at most 120 characters"}, status_code=422)
    snap = demo_snapshot() if sid.startswith(_DEMO_PREFIX) else await _snapshot()
    if not _known(provider, sid, snap):
        return JSONResponse({"detail": "Session not found"}, status_code=404)
    _store.set_alias(provider, sid, name)
    _scan_value = None
    return {"provider": provider, "id": sid, "alias": name.strip() or None,
            "display_name": name.strip() or next(s["suggested_name"] for s in snap["sessions"]
                                                   if s["provider"] == provider and s["id"] == sid)}


@app.post("/api/sessions/{provider}/{sid}/sync-name")
async def sync_name(provider: str, sid: str, request: Request):
    try:
        body = await _json_body(request)
    except ValueError as e:
        return JSONResponse({"detail": str(e)}, status_code=400)
    name = body.get("name")
    if (provider != "codex" or sid.startswith(_DEMO_PREFIX) or not isinstance(name, str)
            or not name.strip() or len(name) > 120):
        return JSONResponse({"detail": "Native title sync supports named Codex sessions only"}, status_code=400)
    snap = demo_snapshot() if sid.startswith(_DEMO_PREFIX) else await _snapshot()
    if not _known(provider, sid, snap):
        return JSONResponse({"detail": "Session not found"}, status_code=404)
    from .native_sync import rename_codex
    result = await asyncio.to_thread(rename_codex, sid, name.strip())
    return JSONResponse(result, status_code=200 if result.get("ok") else 501)


def _manager():
    global _repro
    if _repro is None:
        from .repro import ReproManager
        _repro = ReproManager(STATE_DIR)
    return _repro


@app.post("/api/repro")
async def create_repro(request: Request):
    try:
        body = await _json_body(request)
        job = _manager().create(body)
    except ValueError as e:
        return JSONResponse({"detail": str(e)}, status_code=400)
    except RuntimeError as e:
        return JSONResponse({"detail": str(e)}, status_code=503)
    return JSONResponse({"id": job["id"], "status": job["status"]}, status_code=202)


@app.get("/api/repro/{job_id}")
async def get_repro(job_id: str):
    job = _manager().get(job_id)
    return job if job else JSONResponse({"detail": "Job not found"}, status_code=404)


@app.post("/api/repro/{job_id}/verify")
async def verify_repro(job_id: str, request: Request):
    try:
        await _json_body(request)
        job = _manager().verify(job_id)
    except ValueError as e:
        return JSONResponse({"detail": str(e)}, status_code=400)
    except KeyError:
        return JSONResponse({"detail": "Job not found"}, status_code=404)
    return {"id": job["id"], "status": job["status"]}


@app.post("/api/repro/{job_id}/demo-fix")
async def demo_fix(job_id: str, request: Request):
    try:
        await _json_body(request)
        job = _manager().demo_fix(job_id)
    except ValueError as e:
        return JSONResponse({"detail": str(e)}, status_code=400)
    except KeyError:
        return JSONResponse({"detail": "Job not found"}, status_code=404)
    return {"id": job["id"], "status": job["status"]}


@app.get("/api/repro/{job_id}/download")
async def download_repro(job_id: str):
    try:
        data, filename = _manager().download(job_id)
    except KeyError:
        return JSONResponse({"detail": "Job not found"}, status_code=404)
    except ValueError as e:
        return JSONResponse({"detail": str(e)}, status_code=409)
    return Response(data, media_type="application/zip",
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})


app.mount("/", StaticFiles(directory=Path(__file__).with_name("web"), html=True), name="dashboard")
