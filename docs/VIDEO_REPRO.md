# Repro submission video — 115 seconds

## Recording setup

Use the final packaged Repro.app with Docker running and the runner image installed. Use the disposable Python fixture in `docs/qa/live-repro-fixture`, not a private repository. Start with its buggy `app.py`, an empty native workspace, and Claude Code signed in. Choose **Claude Code**, never the deterministic demo for the model-generation shot. Set the issue to: “discount_total must reject negative quantities with ValueError; it currently returns a negative total.” Rehearse once and reset `app.py` afterward. Actual generation latency varies; a labelled cut is fine, fake progress is not.

| Time | Screen action | Exact narration |
| --- | --- | --- |
| 0:00–0:12 | Click the Repro menu-bar flask, then Open Workspace. | “A bug report is a claim. Repro turns that claim into a test I can inspect, run against the bug, and rerun unchanged after a fix.” |
| 0:12–0:30 | Choose the disposable project using the native folder picker. Paste the issue and select Claude Code. | “Here is a small Python function that accepts a negative quantity. I select this disposable project and describe the expected behavior. Generating sends bounded source snippets to the provider I chose.” |
| 0:30–0:51 | Click Generate. Show actual progress, then the generated pytest code and assertion-failure baseline. | “Claude Code writes a regression test. Repro runs it in a network-disabled Docker container. This baseline fails on an assertion, which is different from a broken import or missing fixture. I still review whether this test actually captures the report.” |
| 0:51–1:10 | Show the generated test, then edit only `app.py` in an editor to reject negative quantities. | “The test asks for a ValueError. I fix the source by rejecting negative quantities. Repro has not edited my checkout or silently rewritten the test to make it pass.” |
| 1:10–1:30 | Click Verify after source fix. Show verified status, unchanged test evidence, and exit 0. | “Now Repro refreshes its source copy and runs the identical test. It requires a real source change and checks the test’s hash. This run passes, so I have a failing-before and passing-after regression.” |
| 1:30–1:44 | Download Evidence with the native save dialog; briefly show ZIP contents. | “The evidence export includes the test and report. It excludes the copied source workspace. I can attach it to a pull request or keep it as the regression record.” |
| 1:44–1:55 | Return to the native panel, then show public README. | “Repro is open source, native on macOS, and currently scoped to Python and pytest. Its prewritten demo is available for trying the workflow without a model call.” |

## Recording boundaries

- Record an actual live generation, not a demo presented as AI-written code.
- If the generated test is unsuitable or fails during setup, redo the run honestly. Do not splice unrelated baseline and verification runs.
- Keep job ID consistent across before/after shots. Preserve the visible test code.
- Say “verified regression under this test,” never “proves the bug is fully fixed.”
- Public repository for the final shot: https://github.com/SharmaNityam/relay. The Repro product entry is [REPRO.md](REPRO.md).
