#!/bin/bash
# Builds a signed, notarized build/Vigil-<version>.dmg for sharing, plus the Sparkle appcast for it.
#   ./release.sh            build/Vigil-<version>.dmg + build/appcast.xml
#   ./release.sh --publish  also creates GitHub release v<version> with both; installed copies update from it
# One-time setup (stores an app-specific password from appleid.apple.com in the keychain):
#   xcrun notarytool store-credentials vigil-notary --apple-id <you@example.com> --team-id W898QUYB63
# The Sparkle signing key must be in the login keychain (README → Auto-update).
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-vigil-notary}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

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

# Appcast with this version only, pointing at the DMG on its GitHub release. Signed after
# stapling, which changes the file. The feed URL is releases/latest/download/appcast.xml,
# so whichever release is latest serves its own appcast.
FEED=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" "$APP/Contents/Info.plist")
REPO_URL="${FEED%/releases/latest/download/appcast.xml}"
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$DMG")  # sparkle:edSignature="…" length="…"
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Vigil</title>
        <item>
            <title>Vigil $VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>$REPO_URL/releases</sparkle:fullReleaseNotesLink>
            <enclosure url="$REPO_URL/releases/download/v$VERSION/$(basename "$DMG")" $SIGNATURE type="application/octet-stream"/>
        </item>
    </channel>
</rss>
XML

# Tags HEAD, so the release fails unless the built commit is pushed.
PUBLISH_CMD=(gh release create "v$VERSION" "$DMG" build/appcast.xml --repo "${REPO_URL#https://github.com/}"
    --target "$(git rev-parse HEAD)" --title "Vigil $VERSION" --generate-notes)

echo
if (( PUBLISH )); then
    "${PUBLISH_CMD[@]}"
    echo "Published: installed copies of Vigil will offer $VERSION."
else
    echo "Ready to share: $DMG"
    echo "Publish the update: ${PUBLISH_CMD[*]}"
fi
