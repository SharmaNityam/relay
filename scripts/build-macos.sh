#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_DESTINATION="${1:-dist/Relay.app}"
REPRO_DESTINATION="${2:-dist/Repro.app}"
command -v swiftc >/dev/null 2>&1 || { echo "swiftc is required." >&2; exit 1; }
[[ -x "$REPO_ROOT/.venv/bin/relay" ]] || { echo "Run uv sync first." >&2; exit 1; }
BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relay-native.XXXXXX")"
trap 'rm -rf "$BUILD_TMP"' EXIT
ICON_TMP="$BUILD_TMP/icons"
mkdir -p "$ICON_TMP"
swiftc -swift-version 5 -O -framework AppKit "$REPO_ROOT/scripts/build-icons.swift" -o "$BUILD_TMP/build-icons"
"$BUILD_TMP/build-icons" "$ICON_TMP" >/dev/null
build_app() {
  local name="$1" destination="$2" accessory="$3" app_dir contents bundle_id
  bundle_id="local.relay.$name"
  if [[ "$name" = Relay ]]; then bundle_id="local.relay.session-command-center"; fi
  if [[ "$destination" = /* ]]; then app_dir="$destination"; else app_dir="$REPO_ROOT/$destination"; fi
  contents="$app_dir/Contents"
  mkdir -p "$contents/MacOS" "$contents/Resources"
  cp "$REPO_ROOT/native/$name.swift" "$BUILD_TMP/main.swift"
  swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI \
    "$REPO_ROOT/native/Shared.swift" "$BUILD_TMP/main.swift" -o "$contents/MacOS/$name"
  printf '%s\n' "$REPO_ROOT" > "$contents/Resources/backend-path.txt"
  iconutil -c icns "$ICON_TMP/$name.iconset" -o "$contents/Resources/$name.icns"
  cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleIconFile</key><string>$name</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><$accessory/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  codesign --force --sign - "$app_dir" >/dev/null 2>&1
  echo "Built $app_dir"
}
build_app Relay "$RELAY_DESTINATION" true
build_app Repro "$REPRO_DESTINATION" true
