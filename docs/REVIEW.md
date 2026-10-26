# Independent adversarial verification

Verified on 2026-10-26 in the Relay checkout. The verifier owns `tests/test_adversarial.py` and this report; implementation fixes were made by the feature owners. The tests use synthetic provider state and temporary repositories, with no personal authentication-store reads or model calls. **Final parent acceptance: 86 tests pass, including all real Docker cases. The unchanged-source regression was fixed and retained.**

## Executed evidence

```
RELAY_TEST_DOCKER=1 .venv/bin/python -m pytest -q --tb=short
76 passed, 1 warning in 3.62s
```

After the additional regressions and owner repairs, the parent reran the full suite:

```
RELAY_TEST_DOCKER=1 .venv/bin/python -m pytest -q --tb=short
86 passed, 1 warning in 7.94s
```

`test_retry_without_source_change_does_not_claim_a_verified_fix` now passes: verification requires a changed source fingerprint and an unchanged test hash.

The independent file now contributes 61 cases, including seven real Docker integration cases. Docker cases are explicitly skipped unless `RELAY_TEST_DOCKER=1` is set. The Docker image used was `relay-repro:local`, ID `sha256:e5adae16606ec6e6043fb613125687e02905ecb8ae762d039a023665c242dd65`. The warning concerns Starlette's deprecated httpx TestClient integration; it did not affect test results.

## What the independent tests establish

- JSONL prefix/suffix parsing preserves completion and interruption evidence across a file over 1 MB, ignores truncated trailing JSON and deeply nested malformed records, and never treats recent file mtime as activity evidence.
- Running activity with invalid or future timestamps becomes unknown; old outstanding activity is labelled stale with inferred provenance. A new user request clears an earlier completion. Historical SQLite rows and archive flags alone are not classified as running or completed.
- Codex recognized SQLite rows hydrate status from an allowed rollout. The database SHA-256 is unchanged after scanning. Credential columns and binary fields do not enter the response. Known nested Codex spawn metadata retains its parent.
- Claude sibling transcripts retain distinct identities when their embedded `sessionId` equals the parent. A recent child is not hidden by older top-level transcripts. Both providers remain represented within the global count limit; zero requested sessions returns none.
- External file/directory symlinks, SQLite symlinks, and external rollout paths are excluded. Authentication-file and tool-argument canaries do not appear in session output. Obvious secret text is redacted. Invalid token counts do not crash collection and an explicit zero remains zero.
- Local aliases persist, remain isolated by provider, leave original session titles intact, tolerate partial local JSON, and are visible immediately after API mutation. Automatic naming stays distinct even when ID suffixes collide.
- API tests reject malformed/foreign Hosts, different origin ports and schemes, malformed origins, non-JSON mutations, invalid JSON, JSON arrays, and bodies over 64 KiB.
- Native Codex sync is mocked: only initialize, initialized, and thread/name/set are sent; no model-turn RPC occurs and the Relay model API key is not inherited. Read-only session polling and local alias edits do not trigger native sync.
- Repro source-copy tests exclude external symlinks and hidden files, enforce aggregate file limits, and leave original source unchanged. Mocked provider workflows refresh only the disposable snapshot after the user changes source and rerun byte-identical tests. Fixture/collection failures are classified separately from regression assertions. Changed canonical test content is rejected by demo-fix integrity validation.
- Evidence ZIPs contain only the generated test, report JSON, and README, and the report's test hash matches the archived bytes.

## Actual Docker evidence

The sandbox test executes inside Docker and checks a nonzero effective UID, read-only root and workspace mount flags, a rejected workspace write, rejected external connection, zero effective capabilities, `NoNewPrivs=1`, 256 MiB memory and 64 process cgroup limits. This checks the running environment rather than command-line strings alone.

The deterministic demo produces an actual pytest assertion failure. Applying the bundled source fix then passes the identical test, and the evidence ZIP contains those same bytes. This verifies the demo execution path, not a live model's ability to write a good regression test.

A separate sleeping pytest process exceeds a two-second test timeout. The runner returns its timeout classification within ten seconds; Docker then reports no remaining container with that exact run's captured name. The test neither enumerates nor removes unrelated containers.

Actual Docker cases also confirm separate setup-error classification for a module-level collection assertion, a failing fixture assertion, and a missing fixture. A deliberate stdout flood is capped at 64 KiB, and the public runner summary excludes its secret canary.

## Findings repaired during this review

The initial run exposed external symlink traversal, duplicate Claude child keys, missing Codex parent metadata, absent SQLite rollout hydration, a broken global count limit, provider starvation, hidden recent children, ambiguous automatic names, invalid running timestamps, and completion state persisting after a new request. Follow-up cases exposed fixture setup misclassification, a missing demo test integrity check, infinite token-count crashes, and loss of reported zero tokens. The original regression assertions pass after owner fixes.

Source review also identified the original Docker ENTRYPOINT/command mismatch, ineffective root collapse and duplicate cyclic tree rendering, and first-launch WebView timing. Those were reported to their owners. Browser/native behavior is verified separately by the parent and interface owner, not by this Python test report.

## Limits and remaining review notes

- Parser evidence is synthetic and covers the enumerated formats; it is not a compatibility guarantee for future Codex/Claude storage schemas. The parent separately performs real local metadata smoke tests.
- Only an explicitly selected source snapshot is sent to generation, and the UI explains this action. Live OpenAI-compatible and Claude generation were not called by this verifier. Provider network/auth behavior is therefore not end-to-end verified here.
- The native RPC exchange is mocked. No external session was renamed during this review. Native app teardown, menu interactions, and service ownership require the parent's native acceptance checks.
- Discovery currently uses fixed known directory layouts. A fixed layout and bounded file contents alone do not bound the number of directory entries or spawn edges visited; the adapter owner added hard directory iterator caps and bounded selected-thread edge queries. Arbitrarily deep Claude subagent directory layouts are not covered by the current fixed-depth parser tests.
- Repro initially retained terminal-job snapshots indefinitely, and Docker inherited the host UID even if it were zero. The backend now caps retained jobs at 50, cleans old owned snapshots, and refuses Docker execution when the host UID is zero. The actual run above used a normal non-root host UID.
- These checks do not establish resistance to a concurrent local attacker replacing files between validation and open, or complete recognition of every possible secret string. They verify the explicit known-path, symlink, field-selection, and obvious-secret cases described above.

## Native migration parent acceptance

The WebKit shell was replaced by two native SwiftUI/AppKit clients. Relay's primary surface is an NSPopover hosted in actual NSGlassEffectView on macOS 26+; Repro has a separate menu-bar panel and native workspace. Both binaries were checked to link AppKit/SwiftUI without WebKit. Parent native UI acceptance confirmed Relay's synthetic popover and child inspector, Repro's assertion baseline and verified unchanged test, and NSSavePanel. A compiled Swift integration harness exercises real typed API decoding and Docker evidence; it caught and repaired acknowledgement/full-job response mismatches. Final engine suite: 87 passed. Native cold start also launched the engine without a terminal. Real Claude Haiku generation was accepted on a disposable fixture after switching from OAuth-excluding bare mode to safe mode. These are parent checks; the earlier independent Python verifier did not perform native UI actions.
