# Architecture and implementation findings

Relay runs a loopback FastAPI service, a static vanilla-JavaScript dashboard, and an optional macOS status-item app. The Python package owns session collection, alias storage, the API, and Repro jobs. The Swift app owns the menu-bar item, starts the local service when no healthy service is responding, and hosts the same dashboard in a `WKWebView`.

## Session collection

`relay/adapters.py` reads only recognized Codex and Claude Code metadata locations. Codex uses a recognized read-only SQLite `threads` schema when it yields rows, then falls back to the known session JSONL layout. Rollout files are accepted only when they remain under the known sessions directory and their IDs match. Claude collection follows the known project/transcript layout and reads bounded JSONL head and tail segments. It skips malformed and oversized lines and applies provider, item, and global limits.

These implementation details reflect edge cases found while exercising the parsers:

- SQLite rows are useful for session identity and task metadata, but timestamps alone are not activity evidence. When a safe matching Codex rollout is available, its event evidence hydrates status, task activity, token information, and parent metadata. The source database remains read-only.
- Child sessions can reuse a parent ID in source records. Adapters derive unique child IDs from child file names where needed, while preserving the parent relationship.
- Directory, database, rollout, and transcript symlinks are checked so collection does not follow paths outside the known source trees.
- An outstanding running or waiting event older than 120 seconds is labelled stale with an inferred-age source. Invalid or future timestamps are unknown. Recent file modification time and archived flags do not imply live or completed work.
- Token metadata is validated as finite and non-negative. Zero is a reported value; missing or malformed token data is unavailable. UI wording says “reported tokens” and does not estimate quotas or cost.
- A malformed or truncated record is isolated from neighboring records and from the other provider's scan.

`relay/store.py` persists display aliases in Relay's local state directory, defaulting to `~/.local/share/relay`. An alias overlays the session display name without modifying provider records. Explicit Codex sync uses a short-lived Codex app-server request to set a thread name; it does not edit the session database. Claude rename remains a user-run `/rename` command copied by the UI.

## Dashboard and native shell

The dashboard polls `/api/sessions` every five seconds and backs off after failures. Demo sessions are requested only when the user enables **Demo data**. Search and provider, status, and project filters operate on the current snapshot. Parent links are drawn within a provider; malformed cycles are broken for display so each session can appear once in the tree. Untrusted session and job values are inserted with DOM text nodes, not HTML parsing.

Status labels include their `status_source` in session details. Token values appear only when a provider reports a valid count. Resume strings and Claude rename syntax are copied to the clipboard; Relay does not execute shell commands.

`native/Relay.swift` polls the local health and session endpoints, presents real session counts and a short attention/recent list in the status menu, and opens the dashboard in a non-persistent WebKit view. It checks health before starting a backend and owns only the process it launches. `scripts/build-macos.sh` compiles the app with the system Swift compiler and writes the source checkout path into the bundle; the Python backend is not embedded.

## Repro execution boundary

`relay/repro.py` accepts only `demo`, `claude`, or `openai` as a generator. A provider run copies eligible Python source into a private disposable work directory, sends bounded snippets to the explicitly selected generator, and writes a generated pytest file into the copy. The original checkout is not changed. Symlinks, hidden paths, non-Python files, caches, and dependency folders are excluded. The copy limit is 100 files, 1 MB per file, and 2 MB total; the prompt includes at most 20 source files and 40 KB of text.

Every test execution uses the `relay-repro:local` Docker image. The container is read-only, non-root, network-disabled, resource-limited, and time-limited. There is no host-execution fallback. The image contains Python and pytest only, so projects needing other packages or non-Python build inputs are out of scope and can fail during setup.

The runner distinguishes `assertion_failure`, `setup_error`, `test_failure`, `invalid_test`, and infrastructure `error`. Only a recognized assertion failure makes the job `reproduced`. A setup error that happens to contain `AssertionError` still does not count. “Reproduced” means the generated test failed on an assertion against the baseline copy; it is not an independent judgment that the test matches the user's report. A human must review that test oracle. Verification refreshes the selected source copy, checks the saved test hash, and runs the unchanged test. The deterministic demo uses a prewritten test and fixture and is labelled as such throughout.

Evidence archives contain the test module, a bounded report, and a short README. They omit the copied source workspace and credentials.

## API and local boundary

The API binds to `127.0.0.1`, validates host and origin on requests, requires JSON for mutations, applies body limits, and sets no-store and frame restrictions. The root serves the local dashboard assets. The API does not enable cross-origin access.

Primary routes are `GET /api/health`, `GET /api/sessions`, local alias `PATCH /api/sessions/{provider}/{id}/name`, explicit Codex `POST /api/sessions/{provider}/{id}/sync-name`, and the `/api/repro` job routes described in [README](../README.md).
