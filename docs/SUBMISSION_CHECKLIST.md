# Submission checklist: Relay and Repro

Work top to bottom. Current state and evidence are in [`qa/SUBMISSION_QA.md`](qa/SUBMISSION_QA.md). Last update: 2026-10-27.

**Source release** (sections 1 to 4) is prepared and published as public source at https://github.com/SharmaNityam/relay. **Native click QA** (section 1) is not complete. **The GitHub release, videos, and submission form** (sections 5 to 7) are separate steps that the owner decides.

## 1. Native click verification (final build)

- [ ] Repro: fail a verify on unchanged source, then press **Retry**. Same test is reused, no model call, hash unchanged. *The error and Retry button were observed. The click is not recorded.*
- [ ] Repro: ambiguous action recovery. A failed Generate or Verify shows the warning, polling settles the run, and the buttons re-enable. *Compiled. Runtime pending.*
- [x] Repro: live generation with Claude Code on the disposable fixture. Reproduced baseline: `assertion_failure`, exit 1. *2026-10-27.*
- [x] Repro: fix `app.py` per `docs/qa/live-repro-fixture/FIX.txt`, then **Verify** on the same job. VERIFIED, exit 0. *2026-10-27.*
- [x] Repro: **Save Evidence** through the native save dialog. The ZIP validates, and its report test hash matches the verified test. *2026-10-27.*
- [x] Repro: sticky footer at the default window size. *Screenshot inspected 2026-10-27. Minimum size pending.*
- [ ] Repro: sticky footer at minimum window size.
- [ ] Repro: full retake.
- [x] Relay: local alias saved in the native inspector. *2026-10-27.*
- [x] Relay: Codex title sync on the owner's own fixture thread, from the menu bar, with explicit confirmation. The session index shows the new name. *2026-10-27.*
- [ ] Relay and Repro: minimum window size, popover close and reopen, quick popover menu actions.
- [ ] Stale success message stays absent after a passing verify on the final build.
- [x] Relay and Repro: cold launch from a directory whose name contains spaces, using the bundled runtime. *2026-10-27.*
- [ ] Runner labels. Source: **Prepare Runner** when no image is present, **Rebuild Runner** once it is. Relay: **Synthetic demo data** and **Demo Data**. Confirm with a native click.

## 2. Automated and package checks

- [x] `.venv/bin/python -m pytest -q` (default): 89 passed, 7 skipped. *Rerun on the current tree 2026-10-27.*
- [x] `RELAY_TEST_DOCKER=1 .venv/bin/python -m pytest -q`: 96 passed. *Run before the final Swift-only change. No Python changed after it.*
- [x] `swiftc -typecheck` for the final native change: exit 0. *Typecheck only.*
- [x] `./scripts/package-macos.sh`: both bundles built, re-signed, zipped. *Final package run.*
- [x] `codesign --verify --deep --strict` on `dist/Relay.app` and `dist/Repro.app`: pass. *Ad-hoc.*
- [x] Review of the diff: no P1 findings. P2-1 (ambiguous POST deleting staged source) and the ambiguous Verify message are fixed in source and compiled. Popover focus is fixed in source and compiled. The stale QA engine is superseded by the final bundles.
- [ ] `./scripts/check-native-client.sh` on a relaunched final bundle, with the exit code recorded. *Not re-run in this pass.*
- [ ] CI: first run on the pushed `main` branch. *Watched after push. Result below.*

## 3. Repository hygiene

- [x] `git diff --check` clean.
- [x] Secret scan of the release files (keys, tokens, `.env`, raw user data): no matches.
- [x] `dist/`, `.venv/`, `.native-check/`, caches, and local temp files are not staged. `.gitignore` already covers them.
- [x] No local or private paths in the docs. Paths are project-relative only.

## 4. Commit and publish

- [x] Commit on `codex/relay` with a feature message. The local `codex/relay` branch is kept.
- [x] Create the public remote `SharmaNityam/relay` (description: "Native macOS Relay and Repro"). Add it as `origin`.
- [x] Push `HEAD` to `main` on the new repository. The repository was empty before the push. No force push.
- [ ] CI runs on the push. *Result recorded in the release notes.*
- [x] Links: README and both video scripts point to https://github.com/SharmaNityam/relay, and the Repro product entry is linked.

## 5. Release (owner decides)

- [ ] Create a GitHub release after the owner's final UI status. Attach `Relay-macOS-arm64.zip` and `Repro-macOS-arm64.zip` from the final package run.
- [ ] Release notes state: ad-hoc signed, not notarized, arm64, tested on macOS 27 only, Docker required for Repro, Claude Code required for live generation.
- [ ] Optional: notarize. This needs an Apple Developer account and is outside the current setup.

## 6. Videos (not started)

- [ ] Relay: record the 100-second script in `docs/VIDEO_RELAY.md` with the final Relay.app. Keep the SAMPLE marker visible.
- [ ] Repro: record the 115-second script in `docs/VIDEO_REPRO.md` with a real Claude Code generation. Do not present the demo as AI-generated.
- [ ] Re-read the claims lists in both scripts against `SUBMISSION_QA.md`. Remove any claim that is not verified.

## 7. Submission form (not started)

- [ ] Gather: repository URL, release URL, both videos, the Repro entry, and the QA report.
- [ ] State the known limits from `SUBMISSION_QA.md` in the submission text.
- [ ] **(owner decides)** Submit.
