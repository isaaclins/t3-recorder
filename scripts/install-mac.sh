#!/usr/bin/env bash
# Build T3 Recorder on Isaac's MacBook, install it, start it at login and give it its upload key. Run from the Mac mini.
# Exit 2: the MacBook is not reachable, nothing happened. Runs again safely after every code change.
set -euo pipefail
cd "$(dirname "$0")/.."
REMOTE=hn-worker/Projects/t3-recorder
IDENTITY="Steward Local Signing"   # self-signed in ~/hn-worker/signing: a stable signature keeps the permissions across rebuilds
ssh -o ConnectTimeout=6 -o BatchMode=yes mac true 2>/dev/null || { echo "MacBook not reachable"; exit 2; }

ssh mac "mkdir -p ~/$REMOTE"
rsync -az --delete --exclude .build --exclude .git ./ "mac:$REMOTE/"
BUILD_NUMBER=$(date +%Y%m%d%H%M)
ssh mac "bash -s" <<REMOTE_SCRIPT
set -euo pipefail
cd ~/$REMOTE
/usr/bin/swift build -c release --product T3Recorder 2>&1 | tail -3
APP=~/Applications/"T3 Recorder.app"
STAGE=\$(mktemp -d)/app.app
mkdir -p "\$STAGE/Contents/MacOS" "\$STAGE/Contents/Resources"
cp .build/release/T3Recorder "\$STAGE/Contents/MacOS/T3Recorder"
sed "s/BUILD_NUMBER/$BUILD_NUMBER/" Resources/Info.plist > "\$STAGE/Contents/Info.plist"
for b in .build/release/*.bundle; do [ -e "\$b" ] && cp -R "\$b" "\$STAGE/Contents/Resources/"; done
KC=~/hn-worker/signing/steward.keychain-db
if [ -f "\$KC" ] && [ -f ~/hn-worker/signing/kc-pass ] && security unlock-keychain -p "\$(cat ~/hn-worker/signing/kc-pass)" "\$KC" 2>/dev/null \
   && codesign --force --options runtime --timestamp=none --entitlements Resources/T3Recorder.entitlements --keychain "\$KC" -s "$IDENTITY" "\$STAGE" 2>/dev/null; then
  echo "signed with $IDENTITY"
else
  codesign --force --options runtime --timestamp=none --entitlements Resources/T3Recorder.entitlements -s - "\$STAGE"
  echo "WARNING: ad-hoc signature, macOS will ask for the permissions again after every rebuild"
fi
pkill -x T3Recorder 2>/dev/null || true
sleep 0.5
mkdir -p ~/Applications
rm -rf "\$APP"
mv "\$STAGE" "\$APP"

SUPPORT=~/Library/"Application Support"/T3Recorder
mkdir -p "\$SUPPORT"
[ -f "\$SUPPORT/upload_key" ] || ssh-keygen -q -t ed25519 -N '' -C t3-recorder-macbook -f "\$SUPPORT/upload_key"

PLIST=~/Library/LaunchAgents/com.isaaclins.t3recorder.plist
mkdir -p ~/Library/LaunchAgents
cat > "\$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.isaaclins.t3recorder</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-a</string><string>\$APP</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
launchctl bootout gui/\$(id -u)/com.isaaclins.t3recorder 2>/dev/null || true
launchctl bootstrap gui/\$(id -u) "\$PLIST"
"\$APP/Contents/MacOS/T3Recorder" --prepare
REMOTE_SCRIPT

# The key can only hand over recordings: forced command, no shell, no forwarding.
PUB=$(ssh mac 'cat ~/Library/"Application Support"/T3Recorder/upload_key.pub')
LINE="command=\"$HOME/house/bin/receive-recording\",restrict $PUB"
grep -qF "$PUB" ~/.ssh/authorized_keys || echo "$LINE" >> ~/.ssh/authorized_keys

ssh mac 'cd "$(mktemp -d)" && echo ok > probe.txt && tar -cf - probe.txt | ssh -i ~/Library/"Application Support"/T3Recorder/upload_key -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new stewie@100.90.249.60 "r-00000000-000000 replace"'
test "$(cat ~/share/recordings/r-00000000-000000/probe.txt)" = ok
rm -rf ~/share/recordings/r-00000000-000000
ssh mac 'open ~/Applications/"T3 Recorder.app"'
echo "installed build $BUILD_NUMBER, upload checked"
