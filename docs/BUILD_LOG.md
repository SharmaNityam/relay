# Local build record

Recorded 2026-10-26 in the project checkout.

## Dashboard and native app

- `node --check relay/web/app.js` passed.
- `bash -n scripts/build-macos.sh` passed.
- `./scripts/build-macos.sh dist/Relay.app` compiled `native/Relay.swift` with `swiftc` and produced the local app bundle at `dist/Relay.app`.
- The app bundle stores the absolute path of this checkout and starts its `.venv/bin/relay` service. Moving the checkout or distributing only the `.app` will break that backend link; rebuild from the intended checkout path.

## Implementation findings to retain

- Codex SQLite rows can hydrate from a matching in-tree rollout. Database timestamps and archived flags alone are not evidence of running or completed state.
- Claude child transcripts can carry the parent's session ID in message records. The child file identifier must remain unique while retaining the parent link.
- External symlinks can escape both metadata trees and Repro source copies; the collectors and copier must reject those paths.
- Old outstanding activity is stale after 120 seconds, while future or invalid timestamps become unknown. File modification time is not used as a live-state signal.
- Malformed token usage must remain unavailable without breaking provider collection; a valid reported zero stays distinct from missing data.
- Pytest fixture and collection errors are not reproduced assertions, even when their output includes the word `AssertionError`. Repro status `reproduced` is reserved for a recognized assertion failure, and the user still reviews whether the test expresses the reported issue.

The initial UI/native packaging pass did not run the project test suite; final parent acceptance is recorded below. The CI workflow runs `uv run pytest` and `node --check relay/web/app.js` on pushes and pull requests; its macOS job builds the app bundle.

## Final parent acceptance

- Full suite with real Docker execution: **86 passed**, one dependency deprecation warning (7.94 seconds).
- Real local collection: 100 sessions, 45 children; every child retained a role and 36 had task text. Missing task text remains unavailable; an agent-path role supplies the name fallback.
- Browser: six labelled synthetic sessions, child details, saved local alias, aligned three-column child rows, and no horizontal overflow at 390px width.
- Real Docker demo: baseline assertion failure, bundled source fix, then unchanged test passed. The demo uses prewritten code, not a model.
- Native app compiled and its dashboard rendered against the local service. Native menu interactions and real Codex title sync remain unverified.
- Live Claude Code Haiku smoke was attempted twice. Both returned expired OAuth before an API call (zero reported cost). Sign-in is required before live model generation can be accepted; mocked provider and safe authentication-error paths pass.
- Final UI correction preserves code newlines and an exit code of zero.

- `uv build` succeeded; the wheel includes all three dashboard assets. Final macOS app build and `git diff --check` passed.

## Native application correction

The user requires system applications, so the original WebKit shell is replaced with two SwiftUI/AppKit clients. `native/Shared.swift` provides typed local engine communication. See NATIVE_PLAN.md.

Claude Code subscription login was confirmed working. The earlier `--bare` flag intentionally excluded OAuth; this was an integration error, not a reason to ask for further login. Replaced it with `--safe-mode` and tested a real Haiku-generated regression on a disposable Python fixture: baseline reproduced an assertion failure; after a source fix, the identical generated test passed (`verified`). No private project was sent.

Two Claude Code Haiku workers implemented the native client files in parallel, with a maximum $2 API-equivalent budget each. The parent handles shared engine integration, packaging, and acceptance.

### Final native/menu-bar acceptance (2026-10-27 IST)

- Both app bundles compile and ad-hoc sign. Neither native client imports or links WebKit.
- Three Claude Code Haiku implementation workers completed for approximately $0.130 API-equivalent reported cost total (native Relay, native Repro, glass popover), excluding the tiny live-generation smoke. The parent verified and corrected API contract mismatches.
- Relay’s real Liquid Glass popover was inspected visually in synthetic mode; running/waiting/failed pills, provider/task cards, attention queue and workspace actions rendered. Clicking a child selected its native inspector. Real sessions were also collected; no real-data screenshot was saved.
- Repro’s native demo reached `reproduced`, then `verified` with unchanged test bytes and displayed exit 0. Native progress correctly leaves Verify incomplete before the source fix. The native evidence-save dialog opened.
- The native typed-client integration check passed: six synthetic sessions, queued response acknowledgement decoding, assertion-failing baseline, passing unchanged test after fixture fix, and ZIP evidence bytes.
- Engine regressions: **87 passed**, one dependency deprecation warning (7.43 seconds).
- The earlier WebKit/dashboard findings above are historical, superseded by this native acceptance. The local web surface is developer diagnostics only.
- Real Codex native title mutation is still tested with a mocked RPC handshake; unrelated live provider sessions were not renamed.

- Cold-start acceptance: stopped the manually started engine and opened Relay; its native launcher brought the engine online and reported Docker available. The native typed-client flow also passed against this GUI-launched engine.
