# Relay demo storyboard

Use a local development run and keep the data-source boundary visible to the audience.

1. Start Relay with `uv run relay serve --port 9778` and open `http://127.0.0.1:9778`. Point out the local-service indicator, source health, status counts, and the status/source details shown when opening a session.
2. Turn on **Demo data** to show a synthetic parent session, child session, waiting work, a failed item, stale activity, and unknown state. Call out that the rows are synthetic and timestamps are absent; the UI does not make them look live.
3. Search or filter the session list, expand or collapse the parent-child tree, and open a session. Edit its local display name, then clear it to return to the suggested name. On Codex, show that native sync is an explicit extra action; on Claude Code, copy the `/rename` command for the user to run.
4. Open **Repro**, choose **Deterministic demo**, and start the bundled prewritten test. Show the Python test and assertion-failure baseline. Explain that this proves only that the test fails against the fixture; it does not prove the test is a good oracle for a real issue.
5. Choose **Apply demo fix + verify**. Relay changes the disposable demo fixture and reruns the same test. Show the verified result and evidence download. The demo uses no model and does not touch a project checkout.

For a provider-backed run, first make Docker and the `relay-repro:local` image available. Choose Claude Code or OpenAI-compatible, enter an issue and the repository path, and press **Generate failing test**. At that point, Relay copies eligible Python files and sends bounded snippets to the selected generator. The run still executes only in Docker. Describe setup failures separately from assertion failures, and review the generated test before treating its result as evidence of the reported issue.
