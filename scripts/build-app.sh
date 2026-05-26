#!/usr/bin/env bash
# Builds Fyrestore.app — a distributable macOS app bundle.
#
# Usage:
#   ./scripts/build-app.sh              # release build, output at dist/Fyrestore.app
#   ./scripts/build-app.sh --debug      # debug build (faster, larger, with symbols)
#
# The resulting .app is UNSIGNED. First-run users will hit Gatekeeper:
#   "Apple cannot check this app for malicious software."
# They right-click → Open once to bypass. To remove the warning, sign + notarize
# the bundle with an Apple Developer ID (separate one-time setup).

set -euo pipefail

# Resolve repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="Fyrestore"
BUNDLE_ID="com.fyrestore.app"
SHORT_VERSION="0.1.0"
BUILD_VERSION="$(date +%Y%m%d%H%M)"
MIN_MACOS="13.0"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="debug"
fi

echo "▶︎ swift build -c $CONFIG"
swift build -c "$CONFIG"

# Locate the built binary. SwiftPM puts arch-specific builds under
# .build/<triple>/<config>, with a convenience symlink at .build/<config>.
BIN_PATH=".build/$CONFIG/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "✗ Built binary not found at $BIN_PATH" >&2
  exit 1
fi

OUT_DIR="dist"
APP_DIR="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"

echo "▶︎ Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Optional icon: drop an .icns at Resources/AppIcon.icns and it'll be picked up.
ICON_KEY_LINE=""
if [[ -f "Resources/AppIcon.icns" ]]; then
  cp "Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
  ICON_KEY_LINE="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
$ICON_KEY_LINE
</dict>
</plist>
PLIST

# Ad-hoc sign the bundle. No Apple Developer ID needed — the `-` identity is
# a synthetic one that gives the binary a stable code signature, which:
#   - stops macOS Keychain prompts on every relaunch (the saved auth attaches
#     to the signature, not the file hash, so rebuilds don't invalidate it),
#   - lets users' "Always Allow" decisions persist across versions of this app.
# This does NOT remove the Gatekeeper "unidentified developer" warning —
# that requires real Developer ID signing + notarization.
echo "▶︎ Ad-hoc signing $APP_DIR"
codesign --force --sign - --options=runtime "$APP_DIR"

# Strip the quarantine attribute so it doesn't get inherited if you re-zip locally.
xattr -cr "$APP_DIR" 2>/dev/null || true

SIZE=$(du -sh "$APP_DIR" | cut -f1)
echo "✓ Built $APP_DIR ($SIZE)"
echo "  Run with:    open $APP_DIR"
echo "  Package via: ./scripts/make-release.sh"
