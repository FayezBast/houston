#!/bin/bash
# Prepare a notarized update locally. Publishing remains a separate step.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HOUSTON_SIGNING_IDENTITY:?Set your Developer ID Application identity}"
: "${HOUSTON_NOTARY_PROFILE:?Set a notarytool Keychain profile name}"
: "${HOUSTON_UPDATE_FEED_URL:?Set the HTTPS appcast URL}"
: "${HOUSTON_UPDATE_PUBLIC_KEY:?Set the Sparkle Ed25519 public key}"
: "${HOUSTON_VERSION:?Set the release version}"
: "${HOUSTON_BUILD:?Set an increasing numeric build number}"
: "${HOUSTON_DOWNLOAD_URL_PREFIX:?Set the HTTPS directory for update archives}"
[[ "$HOUSTON_SIGNING_IDENTITY" == "Developer ID Application:"* ]] || { echo "A Developer ID Application identity is required." >&2; exit 1; }
[[ "$HOUSTON_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ && "$HOUSTON_BUILD" =~ ^[0-9]+$ ]] || { echo "Use numeric release and build versions." >&2; exit 1; }
[[ "$HOUSTON_DOWNLOAD_URL_PREFIX" == https://* ]] || { echo "Downloads must use HTTPS." >&2; exit 1; }
bash scripts/build.sh
APP="$PWD/dist/Houston.app"
NOTARY_ARCHIVE="$PWD/dist/Houston-notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ARCHIVE"
xcrun notarytool submit "$NOTARY_ARCHIVE" --keychain-profile "$HOUSTON_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
mkdir -p dist/updates
ARCHIVE="$PWD/dist/updates/Houston-$HOUSTON_VERSION-$HOUSTON_BUILD.zip"
[[ ! -e "$ARCHIVE" ]] || { echo "Release archive already exists: $ARCHIVE" >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
"$PWD/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" --download-url-prefix "$HOUSTON_DOWNLOAD_URL_PREFIX" "$PWD/dist/updates"
echo "Prepared signed updates in $PWD/dist/updates. Review the appcast before publishing it and its archives."
