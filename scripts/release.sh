#!/usr/bin/env bash
# Ship a new version: every installed T3 Recorder picks it up within the hour. Run on the Mac mini from a clean, pushed main.
# The GitHub release holds everything: DMG, zip, checksums and the Sparkle feed.
# Usage: scripts/release.sh X.Y.Z "what changed, in plain words"
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
cd "$(dirname "$0")/.."
VERSION=${1:?version} NOTES=${2:?what changed}
REPO=isaaclins/t3-recorder
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit everything first"; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not pushed"; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION already exists"; exit 1; }

BUILD=$(date +%Y%m%d%H%M)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CFG=~/.config/t3-recorder

scripts/bundle.sh "$WORK" "$VERSION" "$BUILD" >/dev/null 2>&1
ZIP="T3-Recorder-$VERSION.zip"
DMG="T3-Recorder-$VERSION.dmg"
ditto -c -k --keepParent "$WORK/T3 Recorder.app" "$WORK/$ZIP"

STAGE="$WORK/stage"
mkdir "$STAGE"
ditto "$WORK/T3 Recorder.app" "$STAGE/T3 Recorder.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "T3 Recorder $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$WORK/$DMG"
security unlock-keychain -p "$(cat "$CFG/keychain-pass")" "$CFG/signing.keychain-db"
codesign --force --timestamp=none --keychain "$CFG/signing.keychain-db" -s "T3 Recorder Local Signing" "$WORK/$DMG"

(cd "$WORK" && shasum -a 256 "$DMG" "$ZIP" > SHA256SUMS.txt)
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file "$CFG/sparkle-eddsa-private.key" "$WORK/$ZIP")
cat > "$WORK/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>T3 Recorder</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$NOTES]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/$ZIP" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

# Draft until every file is up: the feed address follows the latest release, so it must never see a half-finished one.
git tag "v$VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" -R "$REPO" --draft --title "T3 Recorder $VERSION" --notes "$NOTES" \
  "$WORK/$DMG" "$WORK/$ZIP" "$WORK/SHA256SUMS.txt" "$WORK/appcast.xml" >/dev/null
gh release edit "v$VERSION" -R "$REPO" --draft=false --latest >/dev/null
echo "released $VERSION (build $BUILD)"
