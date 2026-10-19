#!/bin/bash
# Builds a signed, notarized build/Vigil-<version>.dmg for sharing.
# One-time setup (stores an app-specific password from appleid.apple.com in the keychain):
#   xcrun notarytool store-credentials vigil-notary --apple-id <you@example.com> --team-id W898QUYB63
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-vigil-notary}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

./build.sh --release
APP="build/Vigil.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Vigil-$VERSION.dmg"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Vigil $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo
echo "Ready to share: $DMG"
