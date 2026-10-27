# Relay submission video — 100 seconds

## Recording setup

- Launch the packaged Relay.app. Close the diagnostic browser; this demo is the native menu-bar app.
- Enable **Synthetic demo data** before recording. The on-screen SAMPLE marker must stay visible. Never record private session titles or repository paths.
- Use a clean desktop and a readable display scale. Position the pointer away from text after each click. Record at least 1080p; keep the menu bar visible.
- Clear any test aliases first. Rehearse the exact buttons with the final build, not an older app instance.

| Time | Screen action | Exact narration |
| --- | --- | --- |
| 0:00–0:12 | Show several coding-tool windows, then click Relay’s menu-bar icon. | “When I have several coding agents open, the hard part is knowing which session owns which task, and which one needs me. Relay puts that work in one native Mac menu-bar panel.” |
| 0:12–0:30 | Leave the glass panel open. Point to provider labels, current work, and the attention section. | “This recording uses labelled synthetic sessions. The panel separates Codex and Claude Code, shows their task and last observed state, and brings waiting or failed work to the top. Missing evidence stays unknown.” |
| 0:30–0:52 | Click the child review task. In its native inspector, enter “Review API boundary” as a local alias, Save, then show the updated list title. | “A random session name is not useful context. I can give this child a clear local name, see its parent, and jump back to the parent task. The name persists without rewriting the coding tool’s history.” |
| 0:52–1:10 | Use provider filter, search, clear search, then click Copy Resume Command. Show copy confirmation. | “Search and filters work across the snapshot. The inspector shows where the status came from, and I can copy a resume command without hunting through terminals. Codex title sync is a separate explicit action.” |
| 1:10–1:28 | Close the workspace; click the menu-bar icon again. Show live/synthetic source label and cards. | “Relay is an AppKit and SwiftUI app using the system’s Liquid Glass surface. A local engine reads bounded session metadata. Monitoring makes no model calls, so leaving it open does not burn inference credits.” |
| 1:28–1:40 | Hold on the panel, then show the public repository and README URL. | “Relay is open source. It currently supports Codex and Claude Code on macOS. It makes parallel coding work easier to identify, follow, and resume.” |

## Claims to keep honest

- Do not imply synthetic rows are live agents. Say the label aloud once.
- Session files are observed evidence, not guaranteed instantaneous telemetry or account usage quotas.
- Show a local alias change. Do not claim a live Codex native rename was tested unless the final QA report explicitly records one.
- The panel uses true system Liquid Glass on macOS 26+, native vibrancy on older supported macOS versions.
- Public repository for the final shot: https://github.com/SharmaNityam/relay. Relay and Repro share this repository; the Repro product entry is [REPRO.md](REPRO.md).
