#!/usr/bin/env bash
# Build, ad-hoc sign, and zip Fyrestore.app into a versioned release artifact.
# Prints suggested commands to publish a GitHub Release at the end.
#
# Usage:
#   ./scripts/make-release.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Build (release config + ad-hoc sign happens inside build-app.sh).
./scripts/build-app.sh

APP="dist/Fyrestore.app"
if [[ ! -d "$APP" ]]; then
  echo "✗ $APP not found — build-app.sh did not produce a bundle" >&2
  exit 1
fi

# Read the version baked into Info.plist by build-app.sh.
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
ZIP_PATH="dist/Fyrestore-${VERSION}.zip"

rm -f "$ZIP_PATH"
echo "▶︎ Zipping $ZIP_PATH"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

# Optional: also write a sha256 alongside so users can verify their download.
SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "$SHA  $(basename "$ZIP_PATH")" > "${ZIP_PATH}.sha256"

SIZE=$(du -sh "$ZIP_PATH" | cut -f1)
echo "✓ Built $ZIP_PATH ($SIZE)"
echo "  sha256: $SHA"
echo ""
echo "Publish steps:"
echo ""
echo "  # Tag the release"
echo "  git tag v${VERSION} && git push origin v${VERSION}"
echo ""
echo "  # Create a GitHub Release with the zip attached (requires gh CLI)"
cat <<EOF
  gh release create v${VERSION} ${ZIP_PATH} ${ZIP_PATH}.sha256 \\
      --title "Fyrestore ${VERSION}" \\
      --notes "## Install
1. Download \`Fyrestore-${VERSION}.zip\` and double-click to expand.
2. Drag \`Fyrestore.app\` to /Applications.
3. **First launch**: right-click → Open → Open (to bypass Gatekeeper's unidentified-developer warning). After that, just double-click.

## Notes
This build is ad-hoc signed but not notarized by Apple. The Gatekeeper warning is expected and harmless. Tokens are stored in your macOS Keychain.

sha256: \`${SHA}\`"
EOF
echo ""
echo "  # Or use the GitHub web UI:"
echo "  open https://github.com/<you>/fyrestore/releases/new"
