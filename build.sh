#!/bin/bash
# Builds build/Vigil.app. Requires Xcode or Command Line Tools (Swift 5.9+).
#   ./build.sh            this Mac's architecture, ad-hoc signed (local use)
#   ./build.sh --release  universal (arm64 + x86_64), Developer ID signed with hardened runtime
set -euo pipefail

VERSION="0.3"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1
cd "$(dirname "$0")"

if (( RELEASE )); then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/Vigil
else
    swift build -c release
    BIN=.build/release/Vigil
fi

APP="build/Vigil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Vigil"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for px in 16 32 128 256 512; do
    sips -z $px $px Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vigil</string>
    <key>CFBundleDisplayName</key><string>Vigil</string>
    <key>CFBundleIdentifier</key><string>app.vigil.mac</string>
    <key>CFBundleExecutable</key><string>Vigil</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if (( RELEASE )); then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo
echo "Built $APP ($VERSION)"
echo "Install:  rm -rf /Applications/Vigil.app && cp -R $APP /Applications/ && open /Applications/Vigil.app"
