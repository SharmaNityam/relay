#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DESTINATION="${1:-dist/Relay.app}"
if [[ "$APP_DESTINATION" = /* ]]; then
  APP_DIR="$APP_DESTINATION"
else
  APP_DIR="$REPO_ROOT/$APP_DESTINATION"
fi
CONTENTS="$APP_DIR/Contents"

command -v swiftc >/dev/null 2>&1 || { echo "swiftc is required to build Relay on macOS." >&2; exit 1; }
[[ -x "$REPO_ROOT/.venv/bin/relay" ]] || { echo "Missing $REPO_ROOT/.venv/bin/relay. Install the project into its local virtual environment first." >&2; exit 1; }

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
swiftc -swift-version 5 -O \
  -framework AppKit \
  -framework WebKit \
  "$REPO_ROOT/native/Relay.swift" \
  -o "$CONTENTS/MacOS/Relay"
printf '%s\n' "$REPO_ROOT" > "$CONTENTS/Resources/backend-path.txt"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Relay</string>
  <key>CFBundleIdentifier</key><string>local.relay.session-command-center</string>
  <key>CFBundleName</key><string>Relay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "Built $APP_DIR"
