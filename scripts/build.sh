#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build -c release --arch arm64 --arch x86_64 --disable-sandbox --cache-path "$PWD/.build/cache"
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache")
APP="$PWD/dist/Houston.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN_DIR/Houston" "$APP/Contents/MacOS/Houston"
# Keep symbols in the build directory; users only need the executable.
strip -S -x "$APP/Contents/MacOS/Houston"
cp -R "$BIN_DIR/Houston_Houston.bundle" "$APP/Contents/Resources/"
cp -R "$BIN_DIR/SweetCookieKit_SweetCookieKit.bundle" "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Houston</string>
<key>CFBundleIdentifier</key><string>dev.houston.island</string>
<key>CFBundleName</key><string>Houston</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Embed Sparkle with symlinks intact; SwiftPM only links it into the executable.
SPARKLE_SOURCE="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_SOURCE" ]]; then
    echo "Sparkle framework was not resolved at $SPARKLE_SOURCE" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
# Replace the embedded framework to avoid stale files from an earlier dependency version.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$PWD/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PYTHON'
import base64, os, plistlib, sys
from urllib.parse import urlparse
path = sys.argv[1]
with open(path, 'rb') as source:
    info = plistlib.load(source)
feed = os.environ.get('HOUSTON_UPDATE_FEED_URL', '')
key = os.environ.get('HOUSTON_UPDATE_PUBLIC_KEY', '')
if feed or key:
    parsed = urlparse(feed)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit('HOUSTON_UPDATE_FEED_URL must be an HTTPS URL without credentials.')
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise SystemExit('HOUSTON_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key.')
    info.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=False,
                SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=True,
                SUVerifyUpdateBeforeExtraction=True)
info['CFBundleShortVersionString'] = os.environ.get('HOUSTON_VERSION', info['CFBundleShortVersionString'])
info['CFBundleVersion'] = os.environ.get('HOUSTON_BUILD', info['CFBundleVersion'])
with open(path, 'wb') as output:
    plistlib.dump(info, output)
PYTHON
# Sign helpers inside-out. A stable Developer ID keeps Keychain trust across releases.
SIGNING_IDENTITY="${HOUSTON_SIGNING_IDENTITY:--}"
SIGN_OPTIONS=(--timestamp=none)
if [[ "$SIGNING_IDENTITY" != "-" ]]; then SIGN_OPTIONS=(--options runtime --timestamp); fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for HELPER in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/$HELPER"
done
codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_OPTIONS[@]}" "$SPARKLE"
codesign --force --sign "$SIGNING_IDENTITY" "${SIGN_OPTIONS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
