# Submission checklist: Relay and Repro

Work top to bottom. Current state and evidence are in [`qa/SUBMISSION_QA.md`](qa/SUBMISSION_QA.md). Last update: 2026-10-27.

**Source release** (sections 1 to 4) is published as public source at https://github.com/SharmaNityam/relay, and CI passed on the release commit. **Native click QA** (section 1) has passed for the core Repro and Relay flows; minimum window-layout sign-off and a few focus and recovery checks are still pending. **The GitHub release candidate, videos, and submission form** (sections 5 to 7) are separate steps: release candidate `v0.2.0-rc.1` is published as a prerelease at https://github.com/SharmaNityam/relay/releases/tag/v0.2.0-rc.1 with both macOS ZIPs and `SHA256SUMS.txt`, the video scripts are ready but not recorded, and the form is not done.

## 1. Native click verification (final build)

- [x] Repro: Verify on unchanged source shows the `unchanged_source` error with **Retry**. Retry was clicked after the fix and returned VERIFIED on the same job and test (`QA71770a1d`). *2026-10-27.*
- [ ] Repro: ambiguous action recovery. A failed Generate or Verify shows the warning, polling settles the run, and the buttons re-enable. *Compiled. Runtime pending.*
- [x] Repro: live generation with Claude Code on the disposable fixture. Reproduced baseline: `assertion_failure`, exit 1. *2026-10-27.*
- [x] Repro: fix `app.py` per `docs/qa/live-repro-fixture/FIX.txt`, then **Verify** on the same job. VERIFIED, exit 0. The earlier unchanged-source error is cleared. *2026-10-27.*
- [x] Repro: **Save Evidence** through the native save dialog. The ZIP validates, and its report test hash matches the verified test. *2026-10-27.*
- [x] Repro: runner. With no image present, **Prepare Runner** was clicked and the runner reached Ready. *2026-10-27.*
- [x] Repro: More and Open Workspace from the popover both work. Open Workspace was also tested through the full flow. *2026-10-27.*
- [x] Repro: full retake of the workflow (generate, baseline, verify, fix, retry, save). *2026-10-27.*
- [x] Repro: sticky footer at the default window size. *Screenshot inspected 2026-10-27.*
- [ ] Repro: sticky footer and Generate visibility or scrolling at minimum window size. *Pending owner's manual check.*
- [x] Relay: local alias, filter, and copy, in the native inspector. *Prior native click run, 2026-10-27.*
- [x] Relay: Codex title sync on the owner's own fixture thread, from the menu bar, with explicit confirmation. The session index shows the new name. *2026-10-27.*
- [ ] Relay: final popover retake. Automated click targeting failed (no window available to automation). Not repeated; not recorded as a product failure.
- [ ] Relay and Repro: minimum window size, and Relay popover close and reopen. *Pending owner's manual check.*
- [ ] Quick popover **More** menu actions for Relay. *Repro: passed 2026-10-27. Relay: pending.*
- [x] Stale success message stays absent after a passing verify. The final native UI retake passed on 2026-10-27.
- [ ] Final focus change UI acceptance (popover focus and the ambiguous Verify path). Automated window targeting is unavailable in this environment; a manual pass on the final build is pending.
- [x] Relay and Repro: cold launch from a directory whose name contains spaces, and from a moved path, using the bundled runtime. *2026-10-27.*
- [ ] Runner labels, Relay side. Relay: **Synthetic demo data** and **Demo Data**. Confirm with a native click. Repro's **Prepare Runner** label is confirmed above; **Rebuild Runner** (shown once an image is present) is not yet clicked.

## 2. Automated and package checks

- [x] `.venv/bin/python -m pytest -q` (default): 89 passed, 7 skipped. *Rerun on the current tree 2026-10-27.*
- [x] `RELAY_TEST_DOCKER=1 .venv/bin/python -m pytest -q`: 96 passed. *Run before the final Swift-only change. No Python changed after it.*
- [x] `swiftc -typecheck` for the final native change: exit 0. *Typecheck only.*
- [x] `./scripts/package-macos.sh`: both bundles built, re-signed, zipped. *Final package run.*
- [x] `codesign --verify --deep --strict` on `dist/Relay.app` and `dist/Repro.app`: pass. *Ad-hoc.*
- [x] Review of the diff: no P1 findings. P2-1 (ambiguous POST deleting staged source) and the ambiguous Verify message are fixed in source and compiled. Popover focus is fixed in source and compiled. Runtime retests are pending. The stale QA engine is superseded by the final bundles.
- [x] `./scripts/check-native-client.sh` on the latest live bundled engine: exit 0. The live bundled engine's modules are byte-identical to source. *2026-10-27.*
- [x] HTTP demo job: baseline `assertion_failure`, demo fix verified, exit 0. Error null, test hash unchanged, ZIP report consistent. The default demo verify without the fix returns 400, so the error-retry path is covered by the native click above, not by this job.
- [x] CI: first run on the pushed `main` branch. [Run 40491271383](https://github.com/SharmaNityam/relay/actions/runs/40491271383) on `1dc9c65` passed the Linux `checks` job and the macOS `macos-app` job. Docs-only commit `b4f81b0`: [run 40491800249](https://github.com/SharmaNityam/relay/actions/runs/40491800249) passed.

## 3. Repository hygiene

- [x] `git diff --check` clean.
- [x] Secret scan of the release files (keys, tokens, `.env`, raw user data): no matches.
- [x] `dist/`, `.venv/`, `.native-check/`, caches, and local temp files are not staged. `.gitignore` already covers them.
- [x] No local or private paths in the docs. Paths are project-relative only. The final evidence ZIP is kept outside the repository and is not committed; only its hash metadata is recorded.

## 4. Commit and publish

- [x] Commit on `codex/relay` with a feature message. The local `codex/relay` branch is kept.
- [x] Create the public remote `SharmaNityam/relay` (description: "Native macOS Relay and Repro"). Add it as `origin`.
- [x] Push `HEAD` to `main` on the new repository. The repository was empty before the push. No force push.
- [x] CI runs on the push. Run 40491271383 passed (see section 2).
- [x] Links: README and both video scripts point to https://github.com/SharmaNityam/relay, and the Repro product entry is linked.

## 5. Release

- [x] Release candidate `v0.2.0-rc.1` is published as a prerelease: https://github.com/SharmaNityam/relay/releases/tag/v0.2.0-rc.1. `gh release view` confirms it.
- [x] Attached `Relay-macOS-arm64.zip`, `Repro-macOS-arm64.zip`, and `SHA256SUMS.txt`. The checksums match the uploaded assets.
- [x] Release notes state: ad-hoc signed, not notarized, arm64, tested on macOS 27 only, Docker required for Repro, Claude Code required for live generation. Release notes updated 2026-10-27 with the final native results.
- [ ] Optional: notarize. This needs an Apple Developer account and is outside the current setup.

## 6. Videos (scripts ready, not recorded)

- [ ] Relay: record the 100-second script in `docs/VIDEO_RELAY.md` with the final Relay.app. Keep the SAMPLE marker visible.
- [ ] Repro: record the 115-second script in `docs/VIDEO_REPRO.md` with a real Claude Code generation. Do not present the demo as AI-generated.
- [ ] Re-read the claims lists in both scripts against `SUBMISSION_QA.md`. Remove any claim that is not verified.

## 7. Submission form (not done)

- [ ] Gather: repository URL, release URL, both videos, the Repro entry, and the QA report.
- [ ] State the known limits from `SUBMISSION_QA.md` in the submission text.
- [ ] **(owner decides)** Submit.
