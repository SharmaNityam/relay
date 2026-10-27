import time
import zipfile
from io import BytesIO

import pytest

from relay import repro


def _wait(manager, job_id, status):
    deadline = time.time() + 3
    while time.time() < deadline:
        job = manager.get(job_id)
        if job["status"] == status:
            return job
        time.sleep(0.01)
    raise AssertionError(f"job did not reach {status}: {manager.get(job_id)}")


def test_demo_reproduces_then_verifies_same_test_and_exports_allowlist(tmp_path, monkeypatch):
    outcomes = iter([
        (1, "FAILED test_negative_quantity_is_rejected - Failed: DID NOT RAISE <class 'ValueError'>", None),
        (0, "1 passed", None),
    ])
    monkeypatch.setattr(repro, "_docker_run", lambda work: next(outcomes))
    manager = repro.ReproManager(tmp_path)
    created = manager.create({"provider": "demo", "issue": "negative quantity"})
    baseline = _wait(manager, created["id"], "reproduced")
    original_test = baseline["test_code"]
    assert baseline["baseline"]["outcome"] == "assertion_failure"
    manager.demo_fix(created["id"])
    verified = _wait(manager, created["id"], "verified")
    assert verified["test_code"] == original_test
    assert verified["verification"]["outcome"] == "passed"
    data, _ = manager.download(created["id"])
    with zipfile.ZipFile(BytesIO(data)) as archive:
        assert set(archive.namelist()) == {"test_relay_regression.py", "report.json", "README.txt"}
        assert "app.py" not in archive.namelist()


def test_invalid_test_and_missing_docker_fail_closed(tmp_path, monkeypatch):
    (tmp_path / "bad.py").write_text("def test_broken(:\n", encoding="utf-8")
    result = repro._run_test(tmp_path)
    assert result["outcome"] == "invalid_test"
    monkeypatch.setattr(repro.shutil, "which", lambda name: None if name == "docker" else "/bin/true")
    work = tmp_path / "work"
    work.mkdir()
    (work / "test_relay_regression.py").write_text("def test_ok(): pass\n", encoding="utf-8")
    assert repro._run_test(work)["outcome"] == "error"


@pytest.mark.parametrize("output", [
    "ERROR at setup of test_case\nfixture failed in setup\nAssertionError: assert False",
    "ERROR at setup of test_case\nfixture 'missing' not found",
])
def test_fixture_setup_errors_are_not_reproduced_assertions(tmp_path, monkeypatch, output):
    (tmp_path / "test_relay_regression.py").write_text("def test_case(): pass\n", encoding="utf-8")
    monkeypatch.setattr(repro, "_docker_run", lambda work: (1, output, None))
    assert repro._run_test(tmp_path)["outcome"] == "setup_error"


def test_copy_source_bounds_symlinks_and_hidden_paths(tmp_path):
    source = tmp_path / "repo"
    source.mkdir()
    (source / "app.py").write_text("VALUE = 1\n", encoding="utf-8")
    (source / ".secret.py").write_text("SECRET = 1\n", encoding="utf-8")
    target = tmp_path / "copy"
    repro._copy_source(source, target)
    assert (target / "app.py").read_text() == "VALUE = 1\n"
    assert not (target / ".secret.py").exists()


def test_demo_fix_rejects_changed_test_code(tmp_path, monkeypatch):
    outcomes = iter([(1, "FAILED test - DID NOT RAISE", None)])
    monkeypatch.setattr(repro, "_docker_run", lambda work: next(outcomes))
    manager = repro.ReproManager(tmp_path)
    created = manager.create({"provider": "demo"})
    baseline = _wait(manager, created["id"], "reproduced")
    manager._jobs[created["id"]]["test_code"] += "\n# altered\n"
    with pytest.raises(ValueError, match="integrity"):
        manager.demo_fix(created["id"])


def test_claude_expired_oauth_error_is_actionable_and_redacted(tmp_path, monkeypatch):
    source = tmp_path / "repo"
    source.mkdir()
    (source / "app.py").write_text("VALUE = 1\n", encoding="utf-8")
    payload = (b'{"type":"result","result":"Failed to authenticate: OAuth session expired '
               b'and could not be refreshed; private=CLAUDE_CANARY_123"}')

    class FakeProcess:
        def __init__(self, *args, **kwargs):
            assert "--safe-mode" in args[0]
            assert "--bare" not in args[0]  # Bare mode deliberately ignores subscription OAuth.
            assert kwargs["cwd"] != source
            self.stdin = BytesIO()
            self.stdout = BytesIO(payload)

        def wait(self, **kwargs):
            return 1

    monkeypatch.setattr(repro.shutil, "which", lambda name: "/mock/claude")
    monkeypatch.setattr(repro.subprocess, "Popen", FakeProcess)
    manager = repro.ReproManager(tmp_path / "state")
    created = manager.create({"provider": "claude", "repo_path": str(source), "issue": "Reproduce the bug"})
    result = _wait(manager, created["id"], "error")
    assert result["error"] == "Claude Code authentication expired. Sign in to Claude Code and retry."
    assert "CLAUDE_CANARY_123" not in str(result)


def test_failed_verification_can_retry_same_test_without_another_model_call(tmp_path, monkeypatch):
    source = tmp_path / 'repo'
    source.mkdir()
    (source / 'app.py').write_text(repro.DEMO_SOURCE)
    generated = []
    def generate(*args):
        generated.append(True)
        return repro.DEMO_TEST
    monkeypatch.setattr(repro, '_generate', generate)
    outcomes = iter([(1, 'Failed: DID NOT RAISE ValueError', None), (0, '1 passed', None)])
    monkeypatch.setattr(repro, '_docker_run', lambda work: next(outcomes))
    manager = repro.ReproManager(tmp_path / 'state')
    try:
        created = manager.create({'provider': 'claude', 'repo_path': str(source), 'issue': 'Reject negative quantities'})
        baseline = _wait(manager, created['id'], 'reproduced')
        manager.verify(created['id'])
        failed = _wait(manager, created['id'], 'error')
        assert failed['verification']['outcome'] == 'unchanged_source'
        (source / 'app.py').write_text(repro.DEMO_FIXED)
        retry = manager.verify(created['id'])
        assert retry['verification'] is None and retry['error'] is None
        verified = _wait(manager, created['id'], 'verified')
        assert verified['test_code'] == baseline['test_code']
        assert verified['verification']['outcome'] == 'passed'
        assert verified['error'] is None
        assert 'did not change' not in str(verified['verification'])
        # Event history is kept as an audit trail of the earlier failed attempt.
        assert any('did not change' in event['message'] for event in verified['events'])
        assert len(generated) == 1
    finally:
        manager.shutdown()
