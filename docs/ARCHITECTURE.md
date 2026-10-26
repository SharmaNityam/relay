# Architecture and implementation findings

Relay and Repro are separate native SwiftUI/AppKit applications backed by one shared local Python engine. Relay owns session naming, monitoring and the macOS menu bar. Repro owns the native issue-to-regression workflow. No WebKit or HTML view is used in either application. The optional web surface is retained for developer diagnostics only.

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

## Native applications

`native/Shared.swift` supplies typed session/job models and an asynchronous engine client. Both apps check health before starting the shared engine and reconnect to it. GUI launches include standard tool paths for Claude and Docker. The shared service remains alive if a client closes.

`native/Relay.swift` provides a primary 390×560 menu-bar popover backed by system Liquid Glass on macOS 26+ (native vibrancy fallback), plus an expanded SwiftUI session browser and inspector, native naming controls, filters, parent/child indicators and an AppKit menu-bar item. Session details show status provenance. Codex title sync requires an explicit confirmation; Claude rename and resume commands are clipboard actions.

`native/Repro.swift` provides a separate menu-bar quick panel and expanded workspace with a native repository folder picker, issue editor, generator selector, job progress, multiline test preview and baseline/verification evidence. Downloads use a native save dialog. It never edits the original repository or runs generated tests on the host.

`scripts/build-macos.sh` compiles both apps with the system Swift compiler and ad-hoc signs the bundles. They retain the checkout path and require its Python environment. Portable runtime bundling, notarization and distribution installers remain future work.

## Repro execution boundary

`relay/repro.py` accepts only `demo`, `claude`, or `openai` as a generator. A provider run copies eligible Python source into a private disposable work directory, sends bounded snippets to the explicitly selected generator, and writes a generated pytest file into the copy. The original checkout is not changed. Symlinks, hidden paths, non-Python files, caches, and dependency folders are excluded. The copy limit is 100 files, 1 MB per file, and 2 MB total; the prompt includes at most 20 source files and 40 KB of text.

Every test execution uses the `relay-repro:local` Docker image. The container is read-only, non-root, network-disabled, resource-limited, and time-limited. There is no host-execution fallback. The image contains Python and pytest only, so projects needing other packages or non-Python build inputs are out of scope and can fail during setup.

The runner distinguishes `assertion_failure`, `setup_error`, `test_failure`, `invalid_test`, and infrastructure `error`. Only a recognized assertion failure makes the job `reproduced`. A setup error that happens to contain `AssertionError` still does not count. “Reproduced” means the generated test failed on an assertion against the baseline copy; it is not an independent judgment that the test matches the user's report. A human must review that test oracle. Verification refreshes the selected source copy, checks the saved test hash, and runs the unchanged test. The deterministic demo uses a prewritten test and fixture and is labelled as such throughout.

Evidence archives contain the test module, a bounded report, and a short README. They omit the copied source workspace and credentials.

## API and local boundary

The API binds to `127.0.0.1`, validates host and origin on requests, requires JSON for mutations, applies body limits, and sets no-store and frame restrictions. The root serves the local dashboard assets. The API does not enable cross-origin access.

Primary routes are `GET /api/health`, `GET /api/sessions`, local alias `PATCH /api/sessions/{provider}/{id}/name`, explicit Codex `POST /api/sessions/{provider}/{id}/sync-name`, and the `/api/repro` job routes described in [README](../README.md).
