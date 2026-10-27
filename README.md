# Relay

Relay and Repro are two native macOS system applications. Relay lives in the menu bar and shows what Codex and Claude Code sessions are working on, with meaningful names and parent/child relationships. Repro turns an issue into a regression test and verifies the same test after a source fix. Both interfaces use SwiftUI/AppKit, with a shared local Python engine; neither embeds a website.

Public source: <https://github.com/SharmaNityam/relay>. Relay and Repro are both built from this one repository. The Repro product entry is [docs/REPRO.md](docs/REPRO.md).

## Requirements

For the portable apps (no developer tools needed):

- macOS. The tested release is Apple Silicon on macOS 27; source builds target macOS 13+.
- Docker Desktop or Docker Engine, running, for every Repro test run.
- Claude Code installed and signed in, only when Repro's Claude Code generator is selected, or an OpenAI-compatible endpoint configured for that workflow.
- No Python, uv, or Xcode Command Line Tools. The portable bundles include a managed Python 3.12 runtime.

For a developer build from this checkout:

- Python 3.11 or newer and [uv](https://docs.astral.sh/uv/) for `uv sync`. CI uses Python 3.12.
- Xcode Command Line Tools, because `scripts/build-macos.sh` compiles the menu-bar apps.
- Docker and Claude Code, as above.

## Build and launch the applications

```sh
uv sync --extra dev
./scripts/build-macos.sh
open dist/Relay.app
open dist/Repro.app
```

Both applications start or reconnect to their shared background engine automatically. No terminal server command or browser is required. Both apps live in the macOS menu bar. Relay opens a compact Liquid Glass activity popover, with its full workspace available as a secondary action. Repro has its own menu-bar popover and an expanded workspace with native folder and evidence-save dialogs. Each app can open the other. On macOS 26 or newer the popovers use Apple’s actual `NSGlassEffectView`; older supported versions use native vibrancy.

## Portable submission builds

```sh
./scripts/package-macos.sh
```

This produces movable `Relay.app` and `Repro.app` bundles containing a managed Python 3.12 runtime and pinned engine dependencies, plus ZIPs in `dist/`. They do not need the source checkout or a separate Python installation. Keep the two apps in the same folder for the cross-app buttons. The regular `build-macos.sh` command is a smaller developer build that uses the checkout; `package-macos.sh` produces the portable builds.

The bundles are **ad-hoc signed, not Apple-notarized**. The tested release is Apple Silicon on macOS 27; source builds target macOS 13+. Liquid Glass uses the native system implementation on macOS 26+, with native vibrancy on earlier supported versions. Relay and Repro have each been cold-launched from a directory whose name contains spaces, using their bundled runtime.

Repro still needs Docker Desktop or Docker Engine to run tests and a signed-in Claude Code installation if that generator is selected. In the native workspace, press **Prepare Runner** when no runner image is present, or **Rebuild Runner** once it is. The one-time image build needs Docker running and network access for the initial download. Monitoring sessions itself uses no model or network calls. The shared local engine stays alive when a UI closes so the other app and active runs can continue.

For terminal-based setup, the equivalent command is:

```sh
docker build -t relay-repro:local -f scripts/Dockerfile.repro .
```

The image contains Python 3.12 and pytest. Generated tests never execute on the host.

## Try the native demo

In Relay, turn on **Synthetic demo data** in the popover to inspect sample sessions and naming controls. The workspace shows the same setting as **Demo Data**. These are labelled sample sessions, not live agents.

In Repro, choose **Demo (prewritten, not AI)** from the generator selector, press **Run Demo Test**, then apply the bundled demo fix and verify. This mode makes no model call, and its output is prewritten rather than AI-generated.

For actual model generation, choose **Claude Code (default)**, select a Python repository with the native folder picker, and press **Generate Test**. An authenticated Claude Code installation is required.

## Developer diagnostics

`uv run relay sessions --json` prints session metadata. The optional diagnostic dashboard remains at <http://127.0.0.1:9778> while the engine is running. It is not the system application's interface.

## Session data and names

Relay reads bounded metadata from known Codex and Claude Code session locations. It does not scan credential stores, browser data, or arbitrary project files. Status is accompanied by a source label. A last event more than 120 seconds old can make an outstanding state stale; a timestamp alone does not prove that a session is running or completed. Missing or invalid evidence is shown as unknown. Token counts are reported provider metadata when available, may be partial, and are not quotas or cost estimates.

Display-name changes are stored locally in Relay's state directory. Codex native title sync is an explicit separate action. Claude Code names remain local; Relay offers a `/rename …` command to copy into a Claude Code session. It never runs copied commands.

## Repro and provider configuration

The Repro module handles Python files and pytest. It copies eligible `.py` files into a bounded disposable workspace, sends selected source context to the chosen generator only after **Generate Test** is pressed, then runs the generated test in Docker with network access disabled. The copy is limited to 100 files, 1 MB per file, and 2 MB total; symlinked paths are excluded. Other languages, Python dependencies, and non-Python files are outside this workflow. The original checkout is not edited. The native app first stages the selected Python files into a private bounded temporary copy; verification refreshes that copy from the same original folder. Claude generation uses safe mode with tools disabled, preserving subscription login while skipping customizations.

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

An `assertion_failure` baseline is reported as **reproduced**. This means pytest observed an assertion failure on the original snapshot; it does not establish that the test correctly captures the issue report. Review the generated test and its oracle. Collection, import, and fixture setup errors do not count as a reproduced bug. After a reproduced baseline, verify reruns the integrity-checked test on a refreshed source copy. If verification fails on an unchanged source, the test is kept and Retry reruns that same test without another model call. Downloaded evidence includes the test and report, not source files or credentials.

See [the architecture](docs/ARCHITECTURE.md), [the demo storyboard](docs/DEMO.md), [the local build record](docs/BUILD_LOG.md), and [the implementation plan](docs/PLAN.md).

See the [native migration plan](docs/NATIVE_PLAN.md) for the corrected application architecture.

## Validation

```sh
RELAY_TEST_DOCKER=1 uv run pytest -q
./scripts/check-native-client.sh  # requires the local engine and Docker image
```

Without `RELAY_TEST_DOCKER=1`, the seven Docker-gated tests in `tests/test_adversarial.py` are skipped (89 passed, 7 skipped). With it set and Docker running, that file passes 63 tests.

The native check decodes the actual API responses, runs a real Docker demo baseline, verifies its unchanged test after a source change, and downloads the evidence ZIP. Native UI acceptance includes Relay popover/task selection and Repro’s full demo flow and save dialog.

GitHub Actions runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml) on every push and pull request. A Linux job runs pytest and checks `relay/web/app.js` syntax. A macOS job builds `Relay.app` from source. No CI run is recorded yet; the workflow runs after the branch is pushed.

## Submission material

- [Relay recording script](docs/VIDEO_RELAY.md)
- [Repro recording script](docs/VIDEO_REPRO.md)
- [Repro product entry](docs/REPRO.md)
- [Hands-on acceptance report](docs/qa/SUBMISSION_QA.md)
