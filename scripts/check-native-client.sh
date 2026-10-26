#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relay-client.XXXXXX")"
trap 'rm -rf "$CHECK_TMP"' EXIT
cp "$REPO_ROOT/tests/native_client.swift" "$CHECK_TMP/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework SwiftUI \
  "$REPO_ROOT/native/Shared.swift" "$CHECK_TMP/main.swift" -o "$CHECK_TMP/check"
"$CHECK_TMP/check"
