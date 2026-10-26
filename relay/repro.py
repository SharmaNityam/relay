"""Bounded Repro workflow. Generated tests execute only in the Docker sandbox."""
from __future__ import annotations

import ast
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

MAX_FILES, MAX_FILE, MAX_TOTAL = 100, 1_000_000, 2_000_000
MAX_TEST = 64_000
DOCKER_TIMEOUT = 30
MAX_RETAINED_JOBS = 50
_container_lock = threading.Lock()
_active_containers: set[str] = set()


class ClaudeAuthExpired(RuntimeError):
    """Safe, user-actionable message for a known expired Claude OAuth session."""


def _claude_auth_expired(raw: bytes) -> bool:
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        value = raw.decode("utf-8", "replace")
    strings: list[str] = []

    def collect(item: Any, depth: int = 0) -> None:
        if depth > 5 or len(strings) >= 32:
            return
        if isinstance(item, str):
            strings.append(item[:4096])
        elif isinstance(item, dict):
            for child in list(item.values())[:32]:
                collect(child, depth + 1)
        elif isinstance(item, list):
            for child in item[:32]:
                collect(child, depth + 1)

    collect(value)
    text = " ".join(strings).casefold()
    return "failed to authenticate" in text and "oauth" in text and "session expired" in text and "could not be refreshed" in text

DEMO_SOURCE = '''def discount_total(price, quantity, discount):
    """Return a discounted total."""
    return price * quantity * (1 - discount)
'''
DEMO_TEST = '''"""Prewritten synthetic Relay demo test; no AI generated this test."""

import pytest
from app import discount_total


def test_negative_quantity_is_rejected():
    with pytest.raises(ValueError):
        discount_total(10, -2, 0.1)
'''
DEMO_FIXED = '''def discount_total(price, quantity, discount):
    """Return a discounted total."""
    if quantity < 0:
        raise ValueError("quantity must be non-negative")
    return price * quantity * (1 - discount)
'''


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _safe_summary(text: str, limit: int = 1200) -> str:
    # Never return raw runner output, which can include source lines or secrets.
    low = text.lower()
    if "assertionerror" in low or "assert " in low:
        return "The unchanged test failed on an assertion."
    if "error:" in low or "error in" in low or "collection error" in low:
        return "Pytest could not collect or set up the test."
    if "passed" in low:
        return "The test passed."
    return "Pytest finished with a non-assertion failure."


def _source_fingerprint(root: Path) -> str:
    digest = hashlib.sha256()
    files = sorted(path for path in root.rglob("*.py") if path.name != "test_relay_regression.py")
    for path in files[:MAX_FILES]:
        rel = path.relative_to(root).as_posix()
        digest.update(rel.encode("utf-8", "replace") + b"\0")
        try:
            digest.update(path.read_bytes())
        except OSError:
            continue
    return digest.hexdigest()


def _copy_source(source: Path, target: Path) -> None:
    expanded = source.expanduser()
    if expanded.is_symlink():
        raise ValueError("repo_path must not be a symlink")
    root = expanded.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("repo_path must be a repository directory")
    target.mkdir(parents=True, exist_ok=True)
    files = 0
    total = 0
    excluded = {".git", ".venv", "venv", "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"}
    for directory, dirs, names in os.walk(root, followlinks=False):
        base = Path(directory)
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in excluded
                   and not (base / d).is_symlink()]
        for filename in names:
            source_file = base / filename
            if filename.startswith(".") or source_file.suffix != ".py" or source_file.is_symlink():
                continue
            stat = source_file.stat()
            if not source_file.is_file() or stat.st_size > MAX_FILE:
                continue
            files += 1
            total += stat.st_size
            if files > MAX_FILES or total > MAX_TOTAL:
                raise ValueError("Repository Python sources exceed the copy limits")
            rel = source_file.relative_to(root)
            destination = target / rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            with source_file.open("rb") as src, destination.open("xb") as dst:
                dst.write(src.read(MAX_FILE + 1))
    if files == 0:
        raise ValueError("Repository contains no eligible Python source files")


def _openai_generate(issue: str, source_text: str) -> str:
    from urllib.parse import urlsplit
    base = os.environ.get("RELAY_MODEL_BASE_URL", "").strip().rstrip("/")
    model = os.environ.get("RELAY_MODEL_NAME", "").strip()
    key = os.environ.get("RELAY_MODEL_API_KEY", "")
    parsed = urlsplit(base)
    if (parsed.scheme not in ("https", "http") or not parsed.hostname or not model
            or parsed.username or parsed.password or parsed.query or parsed.fragment):
        raise ValueError("OpenAI-compatible provider is not configured")
    if parsed.scheme != "https" and parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError("Non-loopback model endpoints must use HTTPS")
    url = base if base.endswith("/chat/completions") else base + "/chat/completions"
    prompt = ("Write one pytest regression test module for the stated issue. Return only Python code. "
              "Do not modify source or access the network.\nIssue:\n" + issue[:12000] +
              "\nSelected Python source:\n" + source_text[:40000])
    payload = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}], "temperature": 0}).encode()
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=60) as response:
            data = response.read(65537)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RuntimeError("Model provider request failed") from exc
    if len(data) > 65536:
        raise RuntimeError("Model provider response exceeded limit")
    try:
        result = json.loads(data)
        content = result["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise RuntimeError("Model provider returned an invalid response") from exc
    if not isinstance(content, str):
        raise RuntimeError("Model provider returned no test code")
    return content


def _generate(provider: str, issue: str, root: Path) -> str:
    sources = []
    for path in sorted(root.rglob("*.py"))[:20]:
        try:
            content = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        sources.append(f"### {path.relative_to(root)}\n{content[:4000]}")
    context = "\n\n".join(sources)[:40000]
    if provider == "demo":
        return DEMO_TEST
    if provider == "openai":
        return _openai_generate(issue, context)
    if provider == "claude":
        executable = shutil.which("claude")
        if not executable:
            raise RuntimeError("Claude Code CLI is unavailable")
        prompt = ("Generate one pytest regression test for this issue using only the selected source. "
                  "Return Python code only. Do not edit files.\nISSUE:\n" + issue[:12000] + "\nSOURCE:\n" + context)
        try:
            proc = subprocess.Popen([executable, "--bare", "-p", "--model", "haiku", "--output-format", "json",
                                     "--no-session-persistence", "--tools", "", "--max-turns", "1"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError as exc:
            raise RuntimeError("Claude Code generation could not start") from exc
        output = bytearray()

        def drain():
            assert proc.stdout is not None
            while True:
                chunk = proc.stdout.read(4096)
                if not chunk:
                    break
                if len(output) < 65537:
                    output.extend(chunk[:65537 - len(output)])

        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        try:
            assert proc.stdin is not None
            proc.stdin.write(prompt.encode("utf-8"))
            proc.stdin.close()
            return_code = proc.wait(timeout=60)
        except (subprocess.TimeoutExpired, BrokenPipeError) as exc:
            proc.kill()
            proc.wait()
            reader.join(timeout=1)
            raise RuntimeError("Claude Code generation timed out") from exc
        reader.join(timeout=1)
        raw = bytes(output)
        if len(raw) > 65536:
            raise RuntimeError("Claude Code response exceeded limit")
        if return_code and _claude_auth_expired(raw):
            raise ClaudeAuthExpired("Claude Code authentication expired. Sign in to Claude Code and retry.")
        if return_code:
            raise RuntimeError("Claude Code generation failed")
        try:
            obj = json.loads(raw)
            text = obj.get("result") or obj.get("content")
            if isinstance(text, list):
                text = "\n".join(part.get("text", "") for part in text if isinstance(part, dict))
        except (ValueError, AttributeError):
            text = raw.decode("utf-8", "replace")
        if not isinstance(text, str):
            raise RuntimeError("Claude Code returned no test code")
        return text
    raise ValueError("provider must be demo, claude, or openai")


def _extract_test(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"\A```(?:python|py)?\s*", "", text, flags=re.I)
        text = re.sub(r"\s*```\s*\Z", "", text)
    if not text or len(text.encode("utf-8")) > MAX_TEST:
        raise ValueError("Generated test is empty or too large")
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        raise ValueError("Generated test has invalid Python syntax") from exc
    if not any(isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name.startswith("test") for n in ast.walk(tree)):
        raise ValueError("Generated code contains no pytest test function")
    return text + "\n"


def _docker_run(work: Path) -> tuple[int | None, str, str | None]:
    if not shutil.which("docker"):
        return None, "", "Docker is unavailable; host execution is disabled"
    if os.getuid() == 0:
        return None, "", "Docker Repro refuses to run from a root process"
    name = "relay-repro-" + uuid.uuid4().hex[:16]
    cmd = ["docker", "run", "--rm", "--name", name, "--network=none", "--read-only",
           f"--user={os.getuid()}:{os.getgid()}", "--cap-drop=ALL", "--security-opt=no-new-privileges",
           "--memory=256m", "--cpus=1", "--pids-limit=64", "--tmpfs", "/tmp:rw,noexec,nosuid,size=32m",
           "-v", f"{work}:/workspace:ro", "-w", "/workspace", "-e", "PYTHONDONTWRITEBYTECODE=1",
           "-e", "PYTHONPATH=/workspace/source",
           "relay-repro:local", "python", "-m", "pytest", "-q", "-p", "no:cacheprovider",
           ("/workspace/source/test_relay_regression.py" if (work / "source").exists()
            else "/workspace/test_relay_regression.py")]
    with _container_lock:
        _active_containers.add(name)
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError:
        with _container_lock:
            _active_containers.discard(name)
        return None, "", "Could not start the Docker runner"
    output = bytearray()

    def drain():
        assert proc.stdout is not None
        while True:
            chunk = proc.stdout.read(4096)
            if not chunk:
                break
            if len(output) < 65536:
                output.extend(chunk[:65536 - len(output)])

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    try:
        code = proc.wait(timeout=DOCKER_TIMEOUT)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        reader.join(timeout=1)
        try:
            subprocess.run(["docker", "rm", "-f", name], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            pass
        with _container_lock:
            _active_containers.discard(name)
        return None, "", "Docker execution timed out"
    reader.join(timeout=1)
    with _container_lock:
        _active_containers.discard(name)
    return code, output.decode("utf-8", "replace"), None


def _run_test(work: Path) -> dict[str, Any]:
    test_path = work / "test_relay_regression.py"
    if not test_path.exists() and (work / "source" / "test_relay_regression.py").exists():
        test_path = work / "source" / "test_relay_regression.py"
    try:
        ast.parse(test_path.read_text(encoding="utf-8"))
    except (OSError, SyntaxError):
        return {"outcome": "invalid_test", "exit_code": None, "summary": "Generated test syntax is invalid."}
    code, output, error = _docker_run(work)
    if error:
        return {"outcome": "error", "exit_code": None, "summary": error}
    summary = _safe_summary(output)
    if code == 0:
        outcome = "passed"
    elif ("ERROR collecting" in output or "ERROR at setup" in output or "ERROR at teardown" in output
          or "fixture '" in output and "not found" in output
          or "ImportError while importing" in output or "SyntaxError" in output):
        outcome = "setup_error"
        summary = "Pytest could not collect or import the generated test."
    elif ("AssertionError" in output or "DID NOT RAISE" in output
          or re.search(r"(?:^|\n)E\s+assert\s", output)):
        outcome = "assertion_failure"
        summary = "The generated test failed on an assertion."
    elif code is not None:
        outcome = "test_failure"
        summary = "The generated test failed without a recognized assertion."
    else:
        outcome = "error"
    return {"outcome": outcome, "exit_code": code, "summary": summary}


class ReproManager:
    def __init__(self, state_dir: Path):
        self.root = Path(state_dir).expanduser() / "repro"
        self.root.mkdir(parents=True, exist_ok=True)
        # Jobs live only in memory. Remove orphaned per-job snapshots from prior service runs.
        for child in self.root.iterdir():
            if child.is_dir() and re.fullmatch(r"[0-9a-f]{32}", child.name):
                shutil.rmtree(child, ignore_errors=True)
        self._lock = threading.RLock()
        self._jobs: dict[str, dict[str, Any]] = {}
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="relay-repro")

    def _prune_jobs(self) -> None:
        while len(self._jobs) >= MAX_RETAINED_JOBS:
            evict = next((job_id for job_id, job in self._jobs.items()
                          if job["status"] not in {"queued", "running"}), None)
            if evict is None:
                raise RuntimeError("Repro retention limit reached")
            job = self._jobs.pop(evict)
            shutil.rmtree(job.get("work", ""), ignore_errors=True)

    def shutdown(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)
        if shutil.which("docker"):
            with _container_lock:
                names = list(_active_containers)
            for name in names:
                try:
                    subprocess.run(["docker", "rm", "-f", name], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                except (OSError, subprocess.TimeoutExpired):
                    pass

    def create(self, request: dict[str, Any]) -> dict[str, Any]:
        provider = request.get("provider")
        if provider not in {"demo", "claude", "openai"}:
            raise ValueError("provider must be demo, claude, or openai")
        issue = request.get("issue", "")
        if not isinstance(issue, str) or len(issue) > 12000:
            raise ValueError("issue must be a string of at most 12000 characters")
        if provider != "demo" and not issue.strip():
            raise ValueError("issue is required")
        with self._lock:
            if sum(j["status"] in {"queued", "running"} for j in self._jobs.values()) >= 5:
                raise RuntimeError("Repro queue is full")
            self._prune_jobs()
            job_id = uuid.uuid4().hex
            work = self.root / job_id
            work.mkdir(mode=0o700)
            job = {"id": job_id, "status": "queued", "phase": "generating", "events": [],
                   "test_code": "", "baseline": None, "verification": None, "error": None,
                   "demo": provider == "demo", "download_available": False,
                   "provider": provider, "issue": issue.strip()[:12000], "work": str(work),
                   "test_hash": None, "source_fingerprint": None, "demo_fixed": False}
            repo_path = request.get("repo_path")
            if provider != "demo" and isinstance(repo_path, str) and len(repo_path) <= 4096:
                job["repo_path"] = repo_path
            elif provider != "demo":
                shutil.rmtree(work, ignore_errors=True)
                raise ValueError("repo_path is required for provider generation")
            self._jobs[job_id] = job
            self._pool.submit(self._initial, job_id)
            return self._public(job)

    @staticmethod
    def _public(job: dict[str, Any]) -> dict[str, Any]:
        keys = ("id", "status", "phase", "events", "test_code", "baseline", "verification",
                "error", "demo", "download_available")
        return {key: job.get(key) for key in keys}

    def get(self, job_id: str) -> dict[str, Any] | None:
        with self._lock:
            job = self._jobs.get(job_id)
            return self._public(job) if job else None

    def _event(self, job: dict[str, Any], kind: str, message: str) -> None:
        job["events"].append({"type": kind, "message": message[:200]})
        job["events"] = job["events"][-40:]

    def _initial(self, job_id: str) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job: return
            job["status"], job["phase"] = "running", "generating"
        work = Path(job["work"])
        try:
            if job["demo"]:
                source = work / "app.py"
                source.write_text(DEMO_SOURCE, encoding="utf-8")
                test_code = DEMO_TEST
            else:
                repo = job.get("repo_path")
                if not repo:
                    raise ValueError("repo_path is required for provider generation")
                source_root = work / "source"
                _copy_source(Path(repo), source_root)
                if (source_root / "test_relay_regression.py").exists():
                    raise ValueError("Repository uses the reserved generated-test filename")
                job["source_root"] = str(source_root)
                job["test_root"] = str(source_root)
                test_code = _generate(job["provider"], job["issue"], source_root)
            test_code = _extract_test(test_code)
            test_root = Path(job.get("test_root", work))
            test_path = test_root / "test_relay_regression.py"
            test_path.write_text(test_code, encoding="utf-8")
            job["test_code"] = test_code
            job["test_hash"] = _sha(test_code.encode())
            job["source_fingerprint"] = _source_fingerprint(test_root)
            job["phase"] = "baseline"
            self._event(job, "baseline", "Running generated test against the original source snapshot")
            baseline = _run_test(work)
            job["baseline"] = baseline
            if baseline["outcome"] == "assertion_failure":
                job["status"] = "reproduced"
                job["download_available"] = True
                self._event(job, "reproduced", "The generated test reproduced an assertion failure")
            elif baseline["outcome"] == "passed":
                job["status"] = "not_reproduced"
                self._event(job, "not_reproduced", "The generated test passed on the original source")
            elif baseline["outcome"] == "invalid_test":
                job["status"] = "error"
                self._event(job, "invalid_test", "The generated test has invalid syntax")
            else:
                job["status"] = "error"
                self._event(job, "error", baseline["summary"])
            job["phase"] = "complete"
        except ClaudeAuthExpired as exc:
            job["status"] = "error"
            job["error"] = str(exc)
            job["phase"] = "complete"
            self._event(job, "error", str(exc))
        except Exception as exc:
            job["status"] = "error"
            job["error"] = str(exc)[:200] if isinstance(exc, ValueError) else type(exc).__name__
            job["phase"] = "complete"
            self._event(job, "error", "Repro job could not be completed")

    def _refresh(self, job: dict[str, Any]) -> Path:
        source_root = Path(job["source_root"])
        target = Path(job["work"]) / "source"
        shutil.rmtree(target, ignore_errors=True)
        _copy_source(Path(job["repo_path"]), target)
        return target

    def verify(self, job_id: str) -> dict[str, Any]:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job: raise KeyError(job_id)
            if job["status"] != "reproduced": raise ValueError("Only reproduced jobs can be verified")
            if _sha(job["test_code"].encode()) != job["test_hash"]:
                raise ValueError("Generated test integrity check failed")
            if job["demo"]:
                # Demo verification is available after demo-fix only.
                if not job["demo_fixed"]: raise ValueError("Apply the demo fix before verification")
            job["status"], job["phase"] = "running", "verification"
            self._pool.submit(self._verify_worker, job_id)
            return self._public(job)

    def _verify_worker(self, job_id: str) -> None:
        with self._lock: job = self._jobs[job_id]
        try:
            if job["demo"]:
                root = Path(job["work"])
                (root / "app.py").write_text(DEMO_FIXED, encoding="utf-8")
            else:
                self._refresh(job)
            test_root = Path(job.get("test_root", job["work"]))
            current_fingerprint = _source_fingerprint(test_root)
            if current_fingerprint == job["source_fingerprint"]:
                job["verification"] = {"outcome": "unchanged_source", "exit_code": None,
                                       "summary": "Python source did not change; this pass cannot verify a fix."}
                job["status"] = "error"
                job["phase"] = "complete"
                self._event(job, "verification", "Source snapshot did not change; fix not verified")
                return
            (test_root / "test_relay_regression.py").write_text(job["test_code"], encoding="utf-8")
            result = _run_test(Path(job["work"]))
            job["verification"] = result
            job["status"] = "verified" if result["outcome"] == "passed" else "error"
            self._event(job, "verification", "Unchanged test passed after the source fix" if result["outcome"] == "passed"
                        else "Verification did not pass")
        except Exception as exc:
            job["verification"] = {"outcome": "error", "exit_code": None, "summary": "Verification could not be completed."}
            job["status"] = "error"
            self._event(job, "error", "Verification could not be completed")
        job["phase"] = "complete"

    def demo_fix(self, job_id: str) -> dict[str, Any]:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job: raise KeyError(job_id)
            if not job["demo"] or job["status"] != "reproduced":
                raise ValueError("Only a reproduced disposable demo can be fixed")
            if _sha(job["test_code"].encode()) != job["test_hash"]:
                raise ValueError("Generated test integrity check failed")
            job["demo_fixed"] = True
            job["phase"] = "verification"
            job["status"] = "running"
            self._pool.submit(self._demo_fix_worker, job_id)
            return self._public(job)

    def _demo_fix_worker(self, job_id: str) -> None:
        with self._lock: job = self._jobs[job_id]
        work = Path(job["work"])
        (work / "app.py").write_text(DEMO_FIXED, encoding="utf-8")
        current_fingerprint = _source_fingerprint(work)
        if current_fingerprint == job["source_fingerprint"]:
            job["verification"] = {"outcome": "unchanged_source", "exit_code": None,
                                   "summary": "Python source did not change; this pass cannot verify a fix."}
            job["status"] = "error"
            job["phase"] = "complete"
            self._event(job, "verification", "Demo source did not change; fix not verified")
            return
        test_root = Path(job.get("test_root", work))
        (test_root / "test_relay_regression.py").write_text(job["test_code"], encoding="utf-8")
        result = _run_test(work)
        job["verification"] = result
        job["status"] = "verified" if result["outcome"] == "passed" else "error"
        job["phase"] = "complete"
        self._event(job, "verification", "Unchanged demo test passed after the bundled fix" if result["outcome"] == "passed"
                    else "Demo verification did not pass")

    def download(self, job_id: str) -> tuple[bytes, str]:
        with self._lock:
            job = self._jobs.get(job_id)
            if not job: raise KeyError(job_id)
            if not job["download_available"]: raise ValueError("Evidence is available after a reproduced baseline")
            report = {key: job.get(key) for key in ("id", "status", "demo", "baseline", "verification", "test_hash", "source_fingerprint")}
            with tempfile.TemporaryFile() as buffer:
                with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
                    archive.writestr("test_relay_regression.py", job["test_code"])
                    archive.writestr("report.json", json.dumps(report, indent=2, ensure_ascii=False))
                    archive.writestr("README.txt", "Relay Repro evidence. Source code and provider credentials are excluded.\n")
                buffer.seek(0)
                data = buffer.read(256_000)
        return data, f"relay-repro-{job_id[:8]}.zip"
