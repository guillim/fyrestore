#!/usr/bin/env bash
# Archives the sandboxed App Store build of Fyrestore and uploads it to TestFlight.
# Used by .github/workflows/testflight.yml, and runnable from a Mac with Xcode.
#
# Usage:
#   ./scripts/testflight.sh                 # archive, then upload to TestFlight
#   ./scripts/testflight.sh --archive-only  # archive only: no Apple account needed
#
# The upload needs an App Store Connect API key (App Store Connect > Users and
# Access > Integrations, Admin role so Xcode can create the certificates):
#   APPLE_TEAM_ID     Team ID (developer.apple.com > Membership details)
#   ASC_KEY_ID        identifier of the API key
#   ASC_ISSUER_ID     issuer identifier, shown above the list of keys
#   ASC_KEY_PATH      path to the .p8 file downloaded with the key
#                     (or ASC_PRIVATE_KEY holding the content of that file)
#
# Optional:
#   MARKETING_VERSION overrides the version in Config/App.xcconfig
#   BUILD_NUMBER      overrides the build number (default: UTC timestamp)
#   FYRESTORE_CLIENT_ID / FYRESTORE_CLIENT_SECRET
#                     generate Secrets.swift when it is missing (as in CI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ARCHIVE_ONLY=0
case "${1:-}" in
  "") ;;
  --archive-only) ARCHIVE_ONLY=1 ;;
  *) echo "✗ Unknown argument: $1" >&2; exit 2 ;;
esac

fail() { echo "✗ $*" >&2; exit 1; }

# Check the upload settings before spending minutes on the archive.
if [[ "$ARCHIVE_ONLY" == 0 ]]; then
  missing=()
  for name in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_PRIVATE_KEY:-}" ]] || missing+=("ASC_KEY_PATH (or ASC_PRIVATE_KEY)")
  if (( ${#missing[@]} > 0 )); then
    fail "Missing: ${missing[*]}. See the top of scripts/testflight.sh, or pass --archive-only."
  fi
  if [[ -n "${ASC_KEY_PATH:-}" && ! -f "$ASC_KEY_PATH" ]]; then
    fail "ASC_KEY_PATH does not point to a file: $ASC_KEY_PATH"
  fi
fi

# The Google OAuth client is compiled in from a gitignored file.
if [[ ! -f Sources/Fyrestore/Secrets.swift ]]; then
  if [[ -n "${FYRESTORE_CLIENT_ID:-}" && -n "${FYRESTORE_CLIENT_SECRET:-}" ]]; then
    ./scripts/setup-secrets.sh
  else
    fail "Sources/Fyrestore/Secrets.swift is missing. Run ./scripts/setup-secrets.sh first."
  fi
fi
if grep -q 'clientID = ""' Sources/Fyrestore/Secrets.swift; then
  fail "Secrets.swift has an empty OAuth client: testers could not sign in."
fi

if ! command -v xcodegen >/dev/null; then
  echo "▶︎ Installing XcodeGen"
  brew install xcodegen
fi

echo "▶︎ Generating Fyrestore.xcodeproj"
xcodegen generate --quiet

WORK_DIR="$REPO_ROOT/.build/testflight"
ARCHIVE_PATH="$WORK_DIR/Fyrestore.xcarchive"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# A UTC timestamp always goes up, whether the upload comes from CI or from a Mac.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"

# xcbeautify keeps the log readable; without it, show warnings and errors only.
if command -v xcbeautify >/dev/null; then
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    pretty() { xcbeautify --quiet --renderer github-actions; }
  else
    pretty() { xcbeautify --quiet; }
  fi
  QUIET=()
else
  pretty() { cat; }
  QUIET=(-quiet)
fi

VERSION_OVERRIDE=()
if [[ -n "${MARKETING_VERSION:-}" ]]; then
  VERSION_OVERRIDE=("MARKETING_VERSION=$MARKETING_VERSION")
fi

# The archive is signed "to run locally": that needs no certificate, no profile and
# no registered Mac, and it carries the entitlements. The real App Store signature
# is applied at export, where Xcode creates what it needs with the API key.
echo "▶︎ Archiving (build $BUILD_NUMBER)"
xcodebuild archive \
  -project Fyrestore.xcodeproj \
  -scheme Fyrestore \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  ${QUIET[@]+"${QUIET[@]}"} \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ${VERSION_OVERRIDE[@]+"${VERSION_OVERRIDE[@]}"} \
  | pretty

APP_PLIST="$ARCHIVE_PATH/Products/Applications/Fyrestore.app/Contents/Info.plist"
[[ -f "$APP_PLIST" ]] || fail "The archive holds no Fyrestore.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PLIST")"
echo "✓ Archived Fyrestore $VERSION ($BUILD_NUMBER) at ${ARCHIVE_PATH#"$REPO_ROOT"/}"

if [[ "$ARCHIVE_ONLY" == 1 ]]; then
  exit 0
fi

# Xcode wants the key as a file.
if [[ -z "${ASC_KEY_PATH:-}" ]]; then
  ASC_KEY_PATH="$WORK_DIR/AuthKey.p8"
  (umask 077; printf '%s\n' "$ASC_PRIVATE_KEY" > "$ASC_KEY_PATH")
  trap 'rm -f "$ASC_KEY_PATH"' EXIT
fi
# xcodebuild resolves a relative key path against its own directory, not ours.
ASC_KEY_PATH="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd)/$(basename "$ASC_KEY_PATH")"

cat > "$WORK_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$APPLE_TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

echo "▶︎ Signing and uploading to TestFlight"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
  -exportPath "$WORK_DIR/Export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  ${QUIET[@]+"${QUIET[@]}"} \
  | pretty

echo "✓ Uploaded Fyrestore $VERSION ($BUILD_NUMBER)."
echo "  App Store Connect processes it for a few minutes, then it shows up in TestFlight."
