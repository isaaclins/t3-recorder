#!/usr/bin/env bash
# Ship a new version: every installed T3 Recorder picks it up within the hour. Run on the Mac mini from a clean, pushed main.
# Usage: scripts/release.sh X.Y.Z "what changed, in plain words"
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
cd "$(dirname "$0")/.."
VERSION=${1:?version} NOTES=${2:?what changed}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit everything first"; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not pushed"; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION already exists"; exit 1; }

BUILD=$(date +%Y%m%d%H%M)
TOKEN=$(cat ~/.config/t3-recorder/public-token)
PUBLIC=~/share-public/t3-recorder
BASE=https://agent-machine.isaaclins.com/pub/$TOKEN
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

scripts/bundle.sh "$WORK" "$VERSION" "$BUILD" "$BASE"
ZIP="T3-Recorder-$VERSION.zip"
ditto -c -k --keepParent "$WORK/T3 Recorder.app" "$WORK/$ZIP"
SIGNATURE=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --ed-key-file ~/.config/t3-recorder/sparkle-eddsa-private.key "$WORK/$ZIP")

mkdir -p "$PUBLIC"
cp "$WORK/$ZIP" "$PUBLIC/$ZIP.tmp"
mv "$PUBLIC/$ZIP.tmp" "$PUBLIC/$ZIP"
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
      <enclosure url="$BASE/$ZIP" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
mv "$WORK/appcast.xml" "$PUBLIC/appcast.xml"
# Keep the previous zip: an app that read the old feed a moment ago is still downloading it.
ls -t "$PUBLIC"/*.zip | tail -n +3 | while read -r old; do rm -f "$old"; done

git tag "v$VERSION"
git push -q origin "v$VERSION"
gh release create "v$VERSION" "$PUBLIC/$ZIP" --title "T3 Recorder $VERSION" --notes "$NOTES" >/dev/null
echo "released $VERSION (build $BUILD)"
