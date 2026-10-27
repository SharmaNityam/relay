"""Explicit Codex title sync through the supported app-server JSON-RPC API."""
from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import time


def _codex_executable() -> str | None:
    executable = shutil.which("codex")
    if executable:
        return executable
    # GUI launches have a minimal PATH. Also recognize the official desktop bundle.
    for bundle in ("/Applications/ChatGPT.app", "/Applications/Codex.app"):
        candidate = bundle + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def rename_codex(session_id: str, name: str, timeout: float = 10.0) -> dict:
    if not session_id or len(session_id) > 128 or not name.strip() or len(name) > 120:
        return {"ok": False, "message": "Invalid session ID or title"}
    executable = _codex_executable()
    if not executable:
        return {"ok": False, "message": "Codex CLI is unavailable"}
    # A fresh app-server renames a persisted thread by ID without resuming it.
    env = {k: v for k, v in os.environ.items() if k in {"PATH", "HOME", "USER", "TMPDIR", "LANG", "LC_ALL"}}
    try:
        proc = subprocess.Popen([executable, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=env)
    except OSError:
        return {"ok": False, "message": "Could not start Codex app-server"}
    if proc.stdin is None or proc.stdout is None:
        proc.kill()
        proc.wait()
        return {"ok": False, "message": "Codex app-server streams are unavailable"}
    pending = bytearray()
    total = 0

    def send(message: dict) -> None:
        proc.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        proc.stdin.flush()

    def receive(request_id: int, deadline: float) -> dict | None:
        nonlocal total
        while time.monotonic() < deadline:
            try:
                descriptor = proc.stdout.fileno()
            except (AttributeError, OSError, ValueError):
                descriptor = None
            if descriptor is None:
                chunk = proc.stdout.readline()
            else:
                ready, _, _ = select.select([proc.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                chunk = os.read(descriptor, 4096)
            if not chunk:
                break
            total += len(chunk)
            if total > 65536:
                raise OverflowError
            pending.extend(chunk)
            while b"\n" in pending:
                line, _, rest = pending.partition(b"\n")
                pending[:] = rest
                if not line:
                    continue
                try:
                    value = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    continue
                if isinstance(value, dict) and value.get("id") == request_id:
                    return value
        return None

    try:
        deadline = time.monotonic() + timeout
        send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "relay", "version": "0.1"}}})
        initialized = receive(1, deadline)
        if initialized is None:
            return {"ok": False, "message": "Codex app-server initialization timed out"}
        if initialized.get("error"):
            return {"ok": False, "message": "Codex app-server initialization failed"}
        send({"method": "initialized", "params": {}})
        send({"id": 2, "method": "thread/name/set", "params": {"threadId": session_id, "name": name.strip()}})
        # EOF shuts down a real app-server before its asynchronous title update replies.
        # Keep its input open until the response has arrived, then stop our child below.
        result = receive(2, deadline)
        if result is None:
            return {"ok": False, "message": "Codex app-server title update timed out"}
        if result.get("error"):
            return {"ok": False, "message": "Codex rejected the title update"}
        return {"ok": True, "provider": "codex", "id": session_id, "name": name.strip()}
    except OverflowError:
        return {"ok": False, "message": "Codex app-server response exceeded limit"}
    except (BrokenPipeError, OSError, ValueError):
        return {"ok": False, "message": "Codex app-server request failed"}
    finally:
        kill = getattr(proc, "kill", None)
        if kill:
            try:
                kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=1)
        except (AttributeError, subprocess.TimeoutExpired, OSError, TypeError):
            pass
