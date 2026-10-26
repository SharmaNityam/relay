# Native app demo storyboard

1. Open `dist/Relay.app`. Show the menu-bar activity counts and native session browser. No browser or terminal needs to open.
2. Enable labelled synthetic demo mode. Select a parent and child, filter the list and edit a local name. Show status provenance and the explicit separate Codex title-sync control (disabled for synthetic data).
3. Open the separate `dist/Repro.app`. Choose deterministic demo and generate its prewritten test. Show the assertion-failure baseline, apply the bundled fixture fix and verify the unchanged test. Save the evidence ZIP using the native save dialog.
4. For a live model example, choose Claude Code, use the native folder picker on a disposable Python project, enter the issue and generate a test. Review the test oracle before modifying the source and verifying. Source snippets go to the chosen provider only on generation; all test execution stays in Docker.

The deterministic demo is prewritten and uses no model. Live Claude generation was separately accepted on a disposable fixture. Session monitoring makes no model calls.
