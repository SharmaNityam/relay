# Repro

**A bug report becomes a failing test, then a verified regression.**

Repro is a native macOS menu-bar application with a full SwiftUI workspace. Select a Python project through the native folder picker, describe the bug, choose Claude Code or an OpenAI-compatible provider, and inspect the generated pytest. Repro executes it only in Docker. After fixing your source, verify the identical test. Failed verification can be retried without another model call.

The local app stages only eligible Python source, preserving the original project. The test hash is checked before verification, a real source change is required, and setup errors are distinguished from assertion failures. The evidence ZIP contains the test and report rather than the copied source.

## Run

Use the Repro app from the repository's portable release assets, or build both apps:

```sh
uv sync --extra dev
./scripts/package-macos.sh
open dist/Repro.app
```

Start Docker Desktop, then use **Prepare Runner** in Repro. Choose the clearly labelled prewritten demo to try the flow without a model. For real generation, Claude Code must be installed and signed in, or the optional endpoint environment must be configured before the engine starts.

## What was exercised

The acceptance report records native folder selection, real Claude-generated tests, assertion baseline, source-fix verification, source-unchanged handling, retry, evidence-save dialog and ZIP bytes, engine restart recovery, and movable runtime packaging. The deterministic demo is never presented as AI-generated.

Python/pytest only. Dependencies beyond the bundled runner are not installed automatically. A passing generated assertion does not prove every aspect of the bug is fixed; review the oracle. macOS builds are ad-hoc signed, not notarized.

See [the recording script](VIDEO_REPRO.md), [architecture](ARCHITECTURE.md), and [main setup instructions](../README.md).
