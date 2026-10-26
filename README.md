# Relay

Relay and Repro are two native macOS system applications. Relay lives in the menu bar and shows what Codex and Claude Code sessions are working on, with meaningful names and parent/child relationships. Repro turns an issue into a regression test and verifies the same test after a source fix. Both interfaces use SwiftUI/AppKit, with a shared local Python engine; neither embeds a website.

## Requirements

- Python 3.11 or newer and [uv](https://docs.astral.sh/uv/)
- Docker Desktop or Docker Engine for every Repro test run
- macOS with Xcode Command Line Tools for the menu-bar app
- Claude Code installed and authenticated only when using Claude Code as a Repro test generator, or an OpenAI-compatible endpoint configured for that workflow

## Build and launch the applications

```sh
uv sync --extra dev
./scripts/build-macos.sh
open dist/Relay.app
open dist/Repro.app
```

Both applications start or reconnect to their shared background engine automatically. No terminal server command or browser is required. Both apps live in the macOS menu bar. Relay opens a compact Liquid Glass activity popover, with its full workspace available as a secondary action. Repro has its own menu-bar popover and an expanded workspace with native folder and evidence-save dialogs. Each app can open the other. On macOS 26 or newer the popovers use Apple’s actual `NSGlassEffectView`; older supported versions use native vibrancy.

This is an ad-hoc signed **local developer build** for macOS 13 or later. The app bundles remember the checkout path and need its `.venv`; they are not yet portable, notarized distribution bundles. Rebuild after moving the checkout. The engine is shared and stays alive when either UI closes so the other app and active runs can continue.

To build the isolated Repro runner image:

```sh
docker build -t relay-repro:local -f scripts/Dockerfile.repro .
```

The image contains Python 3.12 and pytest. Generated tests never execute on the host.

## Try the native demo

In Relay, enable the labelled **Demo** mode to inspect synthetic sessions and naming controls. In Repro, choose **Deterministic demo**, generate the prewritten test, then apply the bundled demo fix and verify. This mode makes no model call. For actual model generation, choose Claude Code and select a Python repository with the native folder picker; an authenticated Claude Code installation is required.

## Developer diagnostics

`uv run relay sessions --json` prints session metadata. The optional diagnostic dashboard remains at <http://127.0.0.1:9778> while the engine is running. It is not the system application's interface.

## Session data and names

Relay reads bounded metadata from known Codex and Claude Code session locations. It does not scan credential stores, browser data, or arbitrary project files. Status is accompanied by a source label. A last event more than 120 seconds old can make an outstanding state stale; a timestamp alone does not prove that a session is running or completed. Missing or invalid evidence is shown as unknown. Token counts are reported provider metadata when available, may be partial, and are not quotas or cost estimates.

Display-name changes are stored locally in Relay's state directory. Codex native title sync is an explicit separate action. Claude Code names remain local; Relay offers a `/rename …` command to copy into a Claude Code session. It never runs copied commands.

## Repro and provider configuration

The Repro module handles Python files and pytest. It copies eligible `.py` files into a bounded disposable workspace, sends selected source context to the chosen generator only after **Generate failing test** is clicked, then runs the generated test in Docker with network access disabled. The copy is limited to 100 files, 1 MB per file, and 2 MB total; symlinked paths are excluded. Other languages, Python dependencies, and non-Python files are outside this workflow. The original checkout is not edited. Claude generation uses safe mode with tools disabled, preserving subscription login while skipping customizations.

For an OpenAI-compatible generator, copy `.env.example` to `.env`, edit its values, and load it into the shell before starting Relay:

```sh
cp .env.example .env
# Edit .env, then load its values into this shell.
set -a
. ./.env
set +a
uv run relay serve --port 9778
```

For native app launches, start the configured engine in this shell first so it inherits the endpoint variables. Relay reads these values from its process environment; it does not load `.env` itself. Do not commit `.env`. Monitoring sessions makes no model calls. Claude Code generation uses the installed `claude` executable; background monitoring does not invoke it.

An `assertion_failure` baseline is reported as **reproduced**. This means pytest observed an assertion failure on the original snapshot; it does not establish that the test correctly captures the issue report. Review the generated test and its oracle. Collection, import, and fixture setup errors do not count as a reproduced bug. After a reproduced baseline, verify reruns the integrity-checked test on a refreshed source copy. Downloaded evidence includes the test and report, not source files or credentials.

See [the architecture](docs/ARCHITECTURE.md), [the demo storyboard](docs/DEMO.md), [the local build record](docs/BUILD_LOG.md), and [the implementation plan](docs/PLAN.md).

See the [native migration plan](docs/NATIVE_PLAN.md) for the corrected application architecture.

## Validation

```sh
RELAY_TEST_DOCKER=1 uv run pytest -q
./scripts/check-native-client.sh  # requires the local engine and Docker image
```

The native check decodes the actual API responses, runs a real Docker demo baseline, verifies its unchanged test after a source change, and downloads the evidence ZIP. Native UI acceptance includes Relay popover/task selection and Repro’s full demo flow and save dialog.
