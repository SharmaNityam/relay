# Relay and Repro: submission QA report

Date: 2026-10-27. Scope: the two native macOS apps in this repository, Relay (menu-bar session monitor) and Repro (issue-to-regression-test), with their shared local Python engine. Public source: https://github.com/SharmaNityam/relay.

**Status: source, docs, and packaging are ready for public source release. Native click QA on the final build is not complete.** Parts of the Repro and Relay click flows are still pending (see below), so this report does not claim full click verification or that the project is fully submission-ready. The GitHub release is created separately, after the owner's final UI status.

## Build under test

| Item | Value |
| --- | --- |
| Source | `codex/relay`, based on `95161d4`, plus the release commit. |
| Artifacts | `dist/Relay.app` and `dist/Repro.app` from the final package run, which includes the native focus and ambiguous-action fixes. `dist/` is git-ignored and is not published. |
| Architecture | arm64 only. |
| OS tested | macOS 27 (Darwin 27.0.0) only. |
| OS not tested | macOS 13 to 26. Source builds target macOS 13+, but no run on those versions is recorded. |
| Signing | Ad-hoc. Not Apple-notarized. |
| Engine | Bundled managed Python 3.12 runtime with pinned dependencies. The bundles do not need the checkout or a system Python. |
| CI | `.github/workflows/ci.yml` runs on push and pull request: a Linux job (pytest, `node --check relay/web/app.js`) and a macOS job (`build-macos.sh`). It runs after the release push. |

## Automated and package checks

| Check | Result | Status |
| --- | --- | --- |
| `.venv/bin/python -m pytest -q` (default) | 89 passed, 7 skipped (the 7 are Docker-gated). Rerun on the current tree on 2026-10-27. | Passed |
| `RELAY_TEST_DOCKER=1 .venv/bin/python -m pytest -q` | 96 passed. Run before the final Swift-only change. No Python source changed after it. | Passed |
| `swiftc -typecheck` for the final `native/Repro.swift` change | Exit 0. Typecheck only; not a runtime test. | Passed (typecheck) |
| `./scripts/package-macos.sh` | Both bundles built, re-signed, zipped. | Passed |
| `codesign --verify --deep --strict` on both apps | Pass. Ad-hoc. | Passed |
| Bundled `relay/repro.py`, `native_sync.py`, `adapters.py` vs source | Identical (`cmp`). | Passed |
| ZIP integrity (`unzip -t`) and contents | Pass. Each ZIP contains its `.app` with `Info.plist`, `MacOS/`, `Resources/<App>.icns`, the bundled runtime, and the engine. | Passed |
| Spaced-directory cold launch | Relay and Repro each cold-launched from a directory whose name contains spaces, using the bundled runtime. | Passed (owner observation) |
| Independent review | No P1 findings. | Done |
| `git diff --check` and secret scan of the release files | No whitespace errors. No keys, tokens, or raw user data matched. | Passed |

## Native click evidence (owner observations, 2026-10-27)

| Flow | Observed result | Status |
| --- | --- | --- |
| Repro live generation (Claude Code, fixture) | Reproduced baseline: `assertion_failure`, exit 1. | Passed |
| Repro verify on unchanged source | Error `unchanged_source` shown. Earlier stages kept. **Retry** button visible. | Passed for the error state. Retry click pending. |
| Repro fix and verify, same job | VERIFIED, exit 0. | Passed |
| Repro evidence ZIP | Saved through the native save dialog. The ZIP validates, and its report test hash matches the verified test. | Passed |
| Repro sticky footer and CTA | Actual screenshot inspected at the default size. | Passed at default size. Minimum size pending. |
| Repro quick popover | Actual screenshot inspected. | Visible state passed. Menu actions pending. |
| Relay local alias | Saved in the native inspector and shown in the list. | Passed |
| Relay Codex title sync (owner's fixture thread) | Explicit confirmation from the menu bar. The session index shows the new thread name. | Passed |
| Stale success message | Seen earlier on an engine running older code. The final bundles contain the fix. | Fixed in source and bundles. Retest on the final build pending. |

## Review findings: current status

- **P2-1. Generate could delete staged source after an ambiguous POST failure.** Fixed in `native/Repro.swift`. An ambiguous failure (timeout, dropped connection, 5xx, unreadable reply) keeps the staged copy because the engine may have accepted the job. Only a certain rejection (4xx or connection refused) deletes it. Compiled. Runtime retest pending.
- **P2-2. The QA engine on the diagnostic port was stale.** This was a test-environment issue, not a source bug. The final bundles contain the clear-on-retry and clear-on-pass fixes. Results from the older engine are superseded.
- **Ambiguous Verify message.** A timeout or 5xx on Verify previously showed a raw error with no indication that the run might have started. The final focus and ambiguous-action recovery change handles this in `runAction`: it shows a warning, then polls run status with GETs only. It compiles. Runtime retest pending.
- **Popover focus.** `togglePopover` now makes the popover's window key, matching Relay's `showPopover`. Compiled. Runtime retest pending.

## Remaining click tests (final build)

Native click automation has reported no windows available repeatedly, so these need a manual pass on the final build. Log each with a date and build ID.

1. Repro **Retry** after an unchanged-source verify failure. The same test is reused, no model call is made, and the hash is unchanged.
2. Repro ambiguous-action recovery: the warning appears, polling settles the run, and Generate and Verify re-enable.
3. Repro sticky footer at minimum window size.
4. Relay and Repro minimum window size, and popover close and reopen.
5. Quick popover menu actions.
6. Repro full retake.
7. Stale success message stays absent after a passing verify.

## Synthetic demo vs live fixtures

- **Relay synthetic demo.** Labelled sample sessions, not live agents. The toggle is **Synthetic demo data** in the popover and **Demo Data** in the workspace. The SAMPLE marker must stay visible in any recording.
- **Repro deterministic demo.** Generator option **Demo (prewritten, not AI)**. Prewritten test and fix, no model call. It must never be described as AI-generated.
- **Repro live generation.** **Claude Code (default)** on the disposable fixture in `docs/qa/live-repro-fixture/`. The fixture's `app.py` is the committed buggy version, which omits quantity validation. See `FIX.txt` in that folder.

## Known limits (state these publicly)

- Ad-hoc signed and not notarized. Gatekeeper will warn on first launch.
- Tested on Apple Silicon and macOS 27 only. The macOS 13 to 26 paths are untested.
- Repro needs Docker running for every test run. Python and pytest only.
- Repro's Claude generator needs an authenticated Claude Code install.
- A passing generated assertion does not prove the bug is fixed. The oracle needs human review.
- Relay names are local. Codex title sync is an explicit, separate action. Claude Code names are copy-only, as a `/rename` command.
- Token counts are partial provider metadata, not quotas or costs.

## Verdict

Source, docs, package, and automated checks are complete for public source release. Native click QA on the final build is not complete. The remaining click tests above must pass before anyone calls the native flows fully verified. The release and the videos are separate steps, and the owner decides them.
