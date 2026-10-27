# Relay and Repro: submission QA report

Date: 2026-10-27. Scope: the two native macOS apps in this repository, Relay (menu-bar session monitor) and Repro (issue-to-regression-test), with their shared local Python engine. Public source: https://github.com/SharmaNityam/relay.

**Status: source, docs, packaging, and CI are ready for public source release. The core Repro and Relay click flows have passed on the final build. Minimum window-layout sign-off is still pending, so this report does not claim full click verification or that the project is fully submission-ready.** The release candidate `v0.2.0-rc.1` is published as a prerelease with both macOS ZIPs and `SHA256SUMS.txt`: https://github.com/SharmaNityam/relay/releases/tag/v0.2.0-rc.1.

## Build under test

| Item | Value |
| --- | --- |
| Source | Release commit `1dc9c65`, pushed to public `main`. Local branch `codex/relay` is based on `95161d4` and contains the same release commit. |
| Artifacts | `dist/Relay.app` and `dist/Repro.app` from the final package run, which includes the native focus and ambiguous-action fixes. `dist/` is git-ignored and is not published. |
| Architecture | arm64 only. |
| OS tested | macOS 27 (Darwin 27.0.0) only. |
| OS not tested | macOS 13 to 26. Source builds target macOS 13+, but no run on those versions is recorded. |
| Signing | Ad-hoc. Not Apple-notarized. |
| Engine | Bundled managed Python 3.12 runtime with pinned dependencies. The bundles do not need the checkout or a system Python. |
| CI | `.github/workflows/ci.yml` runs on push and pull request: a Linux job (pytest, `node --check relay/web/app.js`) and a macOS job (`build-macos.sh`). Run [40491271383](https://github.com/SharmaNityam/relay/actions/runs/40491271383) on `1dc9c65` passed both jobs. Docs-only commit `b4f81b0`: [run 40491800249](https://github.com/SharmaNityam/relay/actions/runs/40491800249) passed. |

## Automated and package checks

| Check | Result | Status |
| --- | --- | --- |
| `.venv/bin/python -m pytest -q` (default) | 89 passed, 7 skipped (the 7 are Docker-gated). Rerun on the current tree on 2026-10-27. | Passed |
| `RELAY_TEST_DOCKER=1 .venv/bin/python -m pytest -q` | 96 passed. Run before the final Swift-only change. No Python source changed after it. | Passed |
| `swiftc -typecheck` for the final `native/Repro.swift` change | Exit 0. Typecheck only; not a runtime test. | Passed (typecheck) |
| `./scripts/package-macos.sh` | Both bundles built, re-signed, zipped. | Passed |
| `codesign --verify --deep --strict` on both apps | Pass. Ad-hoc. | Passed |
| Bundled `relay/repro.py`, `native_sync.py`, `adapters.py` vs source | Identical (`cmp`). | Passed |
| Latest live bundled engine vs source | All modules byte-identical to source. | Passed |
| `./scripts/check-native-client.sh` on the latest live bundled engine | Exit 0. Local QA log (not committed): 6 sessions, reproduced baseline, verified unchanged test, ZIP evidence passed. | Passed |
| HTTP demo job | Baseline `assertion_failure`, then demo fix verified, exit 0. Error null, test hash unchanged, ZIP report consistent. The default demo verify without the fix correctly returns 400, so this run does not exercise the error-retry path. | Passed |
| ZIP integrity (`unzip -t`) and contents | Pass. Each ZIP contains its `.app` with `Info.plist`, `MacOS/`, `Resources/<App>.icns`, the bundled runtime, and the engine. | Passed |
| Cold launch from a spaced directory and from a moved location | Relay and Repro each cold-launched from a directory whose name contains spaces, and from a moved path, using the bundled runtime. | Passed (owner observation) |
| Independent review | No P1 findings. | Done |
| `git diff --check` and secret scan of the release files | No whitespace errors. No keys, tokens, or raw user data matched. | Passed |

## Native click evidence (owner observations, 2026-10-27)

| Flow | Observed result | Status |
| --- | --- | --- |
| Repro live generation (Claude Code, fixture) | Reproduced baseline: `assertion_failure`, exit 1. The generated test asserts a `ValueError` for a negative quantity on the synthetic `discount_total` fixture. | Passed |
| Repro verify on unchanged source | Verify was clicked on unchanged source (job `QA71770a1d`). The `unchanged_source` error and **Retry** button appeared. Retry was clicked after the fix and returned VERIFIED on the same job and test. The native click was performed. An earlier note that the Retry click was not recorded was incorrect. | Passed |
| Repro final retake (final `dist/Repro.app`) | Generate, then baseline exit 1. Verify on unchanged source showed the error with Retry. The source fix was applied, then Retry on the same job returned VERIFIED, exit 0, "The test passed." The earlier `unchanged_source` error is gone. The failed attempt remains only in the timeline. | Passed |
| Repro fix and verify, same job | VERIFIED, exit 0. | Passed |
| Repro evidence ZIP | Saved through the native save dialog. The ZIP validates, and its report test hash matches the verified test. See the receipt below. | Passed |
| Repro runner | No runner image present, Docker running. **Prepare Runner** clicked, and the runner reached **Ready**. | Passed |
| Repro More and Open Workspace | Both work from the popover. Open Workspace was also tested through the full flow. | Passed |
| Repro sticky footer and CTA | Actual screenshot inspected at the default size. | Passed at default size. Minimum size pending. |
| Repro quick popover | Actual screenshot inspected. Visible state and More menu actions passed. | Passed |
| Relay local alias, filter, and copy | Passed in the prior native click run. Alias saved in the native inspector and shown in the list. | Passed |
| Relay Codex title sync (owner's fixture thread) | Explicit confirmation from the menu bar. The session index shows the new thread name. | Passed |
| Relay final popover retake | Automated click targeting failed (no window available to automation). Not repeated. This is a test-tooling limitation, not a recorded product failure. | Not repeated |
| Stale success message | Seen earlier on an engine running older code. The current live engine clears the stale error in API and test runs. The native UI retake on the final build passed: the error cleared on the passing verify. | Passed |
| Minimum window layout (Repro and Relay) | Automated resize drag failed (no windows available to automation). The owner's manual check is pending: whether Generate is visible and scrollable at the minimum size. | Pending |

## Latest evidence receipt (2026-10-27)

The evidence ZIP is not committed. It stays outside the repository. The receipt is identified by its file hash and test hash only.

| Item | Value |
| --- | --- |
| Fixture | `docs/qa/live-repro-fixture/`: synthetic `discount_total` bug. The committed buggy `app.py` was restored after the run. Git was clean afterward. |
| Evidence ZIP | 817 bytes. SHA-256 `415f4428fdcf864ded9c066f90ea171c6e356e885b4775a396616bf4aad2c854` |
| ZIP members | `test_relay_regression.py` (171 B), `report.json` (503 B), `README.txt` (73 B) |
| `report.json` | `status` verified. `demo` false. Baseline `assertion_failure`, exit 1. Verification `passed`, exit 0. |
| Test hash | `82e8e7fbadd26475fdace9688b7bf39bbf59cc236f7e62c19b5cbafc54b896c4`. Matches the SHA-256 of the test file inside the ZIP. |

## Review findings: current status

- **P2-1. Generate could delete staged source after an ambiguous POST failure.** Fixed in `native/Repro.swift`. An ambiguous failure (timeout, dropped connection, 5xx, unreadable reply) keeps the staged copy because the engine may have accepted the job. Only a certain rejection (4xx or connection refused) deletes it. Compiled. Runtime retest pending.
- **P2-2. The QA engine on the diagnostic port was stale.** This was a test-environment issue, not a source bug. The final bundles contain the clear-on-retry and clear-on-pass fixes. Results from the older engine are superseded. The current live engine clears the stale error in API and test runs, and the native UI retake passed.
- **Ambiguous Verify message.** A timeout or 5xx on Verify previously showed a raw error with no indication that the run might have started. The final focus and ambiguous-action recovery change handles this in `runAction`: it shows a warning, then polls run status with GETs only. Read back from commit `1dc9c65`: the `runAction` catch shows "Could not confirm whether the action started … Checking run status now", then calls `startPolling(reconnecting: true)` with no second POST. It is implemented and typechecked. The runtime fault-injection test was not performed.
- **Popover focus.** `togglePopover` now makes the popover's window key, matching Relay's `showPopover`. Compiled. The final popover focus check is not verified by click. Automated targeting failed in this environment.

## Remaining click tests (final build)

Automated window targeting is unavailable in this environment (no windows available to automation). The items below need a manual pass on the final build. Log each with a date and build ID.

1. Repro ambiguous-action recovery: the warning appears, polling settles the run, and Generate and Verify re-enable. **Pending.**
2. Repro sticky footer and Generate visibility or scrolling at minimum window size. **Pending.**
3. Relay and Repro minimum window size, and Relay popover close and reopen. **Pending.**
4. Quick popover **More** menu actions. Repro: **passed** (2026-10-27). Relay: **pending.**
5. Repro full retake. **Passed** (2026-10-27, see the native click table).
6. Stale success message stays absent after a passing verify, retested in the native UI after the backend fix. **Passed** (2026-10-27).
7. Final focus change UI acceptance (popover focus and the ambiguous Verify path). **Pending.**

Done: Repro **Retry** after an unchanged-source verify failure (job `QA71770a1d`), and the final Repro retake with its evidence ZIP and runner check.

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

Source, docs, package, CI, and the automated checks are complete for public source release. The core native flows have passed on the final build: Repro baseline, unchanged-source error and Retry, fix and verify, evidence save, runner preparation, stale-error clearing, and Repro More and Open Workspace; Relay's alias, filter, copy, and Codex sync. Native click QA is **not fully complete**: minimum window-layout sign-off, the final Relay popover retake, Repro's ambiguous-action recovery, and the focus and ambiguous Verify check remain pending. Release candidate `v0.2.0-rc.1` is published as a prerelease with both ZIPs and `SHA256SUMS.txt`. Recording scripts are ready, but the videos are not recorded. The submission form is not done.
