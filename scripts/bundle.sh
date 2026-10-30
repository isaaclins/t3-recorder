#!/usr/bin/env bash
# Build and sign "T3 Recorder.app". Usage: scripts/bundle.sh <out dir> <version> <build number>
# Signed with the app's own identity in ~/.config/t3-recorder (mini only): it never changes, so macOS keeps the
# Screen Recording, Microphone and Accessibility permissions across updates.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")/.."
OUT=$1 VERSION=$2 BUILD=$3
CFG=~/.config/t3-recorder
KC=$CFG/signing.keychain-db
IDENTITY="T3 Recorder Local Signing"

swift build -c release --product T3Recorder 2>&1 | tail -1
APP="$OUT/T3 Recorder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/T3Recorder "$APP/Contents/MacOS/T3Recorder"
sed -e "s/VERSION_NUMBER/$VERSION/" -e "s/BUILD_NUMBER/$BUILD/" -e "s#PUBLIC_KEY#$(cat Resources/sparkle-public-key.txt)#" \
  Resources/Info.plist > "$APP/Contents/Info.plist"
for b in .build/release/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
ditto .build/release/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/T3Recorder" 2>/dev/null || true

security unlock-keychain -p "$(cat "$CFG/keychain-pass")" "$KC"
sign() { codesign --force --options runtime --timestamp=none --keychain "$KC" -s "$IDENTITY" "$@"; }
S="$APP/Contents/Frameworks/Sparkle.framework"
sign "$S/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$S/Versions/B/XPCServices/Downloader.xpc"
sign "$S/Versions/B/Autoupdate"
sign "$S/Versions/B/Updater.app"
sign "$S"
sign --entitlements Resources/T3Recorder.entitlements "$APP"
codesign --verify --deep --strict "$APP"
