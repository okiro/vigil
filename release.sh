#!/bin/bash
# Builds a signed, notarized build/Vigil-<version>.dmg for sharing, plus the Sparkle appcast for it.
#   ./release.sh            build/Vigil-<version>.dmg + build/appcast.xml
#   ./release.sh --publish  also creates GitHub release v<version> with both; installed copies update from it
# CI (.github/workflows/release.yml) runs --publish on every push to main.
#
# The version comes from the commits since the last v* tag (Conventional Commits):
# a breaking change (`feat!: …` or a "BREAKING CHANGE" line) bumps major, `feat: …` minor,
# anything else patch.
#
# Credentials: CI passes them in the environment (APPLE_ID, APPLE_APP_PASSWORD,
# SPARKLE_PRIVATE_KEY). Locally they come from the keychain — the Sparkle key from
# generate_keys, and notarization from a profile stored once with:
#   xcrun notarytool store-credentials vigil-notary --apple-id <you@example.com> --team-id W898QUYB63
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${NOTARY_PROFILE:-vigil-notary}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM_ID="W898QUYB63"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

if (( PUBLISH )); then git fetch --tags --quiet; fi
LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*')
SUBJECTS=$(git log --format=%s "$LAST_TAG..HEAD")
MESSAGES=$(git log --format=%B "$LAST_TAG..HEAD")
if [[ -z "$SUBJECTS" ]]; then
    echo "Nothing to release: no commits since $LAST_TAG."
    exit 0
fi
IFS=. read -r MAJOR MINOR PATCH <<< "${LAST_TAG#v}"
if grep -qE '^[a-z]+(\([^)]*\))?!:' <<< "$SUBJECTS" || grep -q '^BREAKING CHANGE' <<< "$MESSAGES"; then
    VERSION="$((MAJOR + 1)).0.0"
elif grep -qE '^feat(\([^)]*\))?:' <<< "$SUBJECTS"; then
    VERSION="$MAJOR.$((MINOR + 1)).0"
else
    VERSION="$MAJOR.$MINOR.$((${PATCH:-0} + 1))"
fi
echo "Releasing $VERSION (previous: $LAST_TAG)"

VERSION="$VERSION" ./build.sh --release
APP="build/Vigil.app"
DMG="build/Vigil-$VERSION.dmg"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Vigil $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ -n "${APPLE_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$TEAM_ID")
else
    NOTARY_AUTH=(--keychain-profile "$PROFILE")
fi
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# Appcast with this version only, pointing at the DMG on its GitHub release. Signed after
# stapling, which changes the file. The feed URL is releases/latest/download/appcast.xml,
# so whichever release is latest serves its own appcast.
FEED=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" "$APP/Contents/Info.plist")
REPO_URL="${FEED%/releases/latest/download/appcast.xml}"
SIGN_UPDATE=.build/artifacts/sparkle/Sparkle/bin/sign_update
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    SIGNATURE=$("$SIGN_UPDATE" --ed-key-file - "$DMG" <<< "$SPARKLE_PRIVATE_KEY")
else
    SIGNATURE=$("$SIGN_UPDATE" "$DMG")
fi  # sparkle:edSignature="…" length="…"
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
    echo "Published: installed copies of Vigil will update to $VERSION."
else
    echo "Ready to share: $DMG"
    echo "Publish the update: ${PUBLISH_CMD[*]}"
fi
