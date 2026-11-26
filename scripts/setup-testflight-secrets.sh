#!/usr/bin/env bash
# Stores the six secrets the TestFlight workflow needs in the GitHub repository,
# with the `gh` CLI. Run once, and again whenever a value changes.
#
# Usage:
#   export APPLE_TEAM_ID="ABCDE12345"
#   export ASC_KEY_ID="XXXXXXXXXX"
#   export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#   export ASC_KEY_PATH="$HOME/Downloads/AuthKey_XXXXXXXXXX.p8"
#   ./scripts/setup-testflight-secrets.sh
#
# The Google OAuth client is read from Sources/Fyrestore/Secrets.swift, unless
# FYRESTORE_CLIENT_ID and FYRESTORE_CLIENT_SECRET are set.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "✗ $*" >&2; exit 1; }

command -v gh >/dev/null || fail "The GitHub CLI is missing: brew install gh"

# Value of `static let <name> = "…"` in the generated Secrets.swift.
secret_from_swift() {
  sed -n "s/.*static let $1 = \"\(.*\)\".*/\1/p" Sources/Fyrestore/Secrets.swift 2>/dev/null | head -n 1
}
FYRESTORE_CLIENT_ID="${FYRESTORE_CLIENT_ID:-$(secret_from_swift clientID)}"
FYRESTORE_CLIENT_SECRET="${FYRESTORE_CLIENT_SECRET:-$(secret_from_swift clientSecret)}"

missing=()
for name in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH FYRESTORE_CLIENT_ID FYRESTORE_CLIENT_SECRET; do
  [[ -n "${!name:-}" ]] || missing+=("$name")
done
if (( ${#missing[@]} > 0 )); then
  fail "Missing: ${missing[*]}. See the top of this script."
fi
[[ -f "$ASC_KEY_PATH" ]] || fail "ASC_KEY_PATH does not point to a file: $ASC_KEY_PATH"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo "▶︎ Setting secrets on $REPO"
for name in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID FYRESTORE_CLIENT_ID FYRESTORE_CLIENT_SECRET; do
  printf '%s' "${!name}" | gh secret set "$name"
done
gh secret set ASC_PRIVATE_KEY < "$ASC_KEY_PATH"

echo "✓ Done. Start an upload with: gh workflow run testflight.yml"
