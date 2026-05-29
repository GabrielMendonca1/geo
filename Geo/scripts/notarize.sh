#!/bin/bash
set -euo pipefail

: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the notarytool keychain profile name (created via: xcrun notarytool store-credentials)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/build"
DMG="${1:-$BUILD_DIR/Geo.dmg}"

if [ ! -f "$DMG" ]; then
    echo "ERROR: artifact not found: $DMG" >&2
    exit 1
fi

echo "==> Submitting $DMG to notarytool (profile: $NOTARY_PROFILE)..."
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
    echo "ERROR: notarization failed." >&2
    echo "       Inspect the log: xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\"" >&2
    exit 1
fi

echo "==> Stapling ticket..."
xcrun stapler staple "$DMG"

echo "==> Validating staple..."
xcrun stapler validate "$DMG"

echo "==> Gatekeeper assessment..."
spctl -a -vvv --type install "$DMG"

echo ""
echo "==> Notarized + stapled. Ready to distribute:"
echo "    $DMG"
