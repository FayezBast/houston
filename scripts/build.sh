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
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# A stable signing certificate preserves Keychain trust across rebuilds.
codesign --force --sign "${HOUSTON_SIGNING_IDENTITY:--}" "$APP"
echo "Built $APP"
