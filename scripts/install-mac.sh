#!/usr/bin/env bash
# First install on Isaac's MacBook, from the newest release. Afterwards Sparkle keeps it current. Run from the Mac mini.
# Exit 2: the MacBook is not reachable, nothing happened.
set -euo pipefail
ssh -o ConnectTimeout=6 -o BatchMode=yes mac true 2>/dev/null || { echo "MacBook not reachable"; exit 2; }
BASE=https://agent-machine.isaaclins.com/pub/$(cat ~/.config/t3-recorder/public-token)
ZIP=$(basename "$(ls -t ~/share-public/t3-recorder/*.zip | head -1)")

ssh mac "bash -s" <<REMOTE_SCRIPT
set -euo pipefail
APP=~/Applications/"T3 Recorder.app"
WORK=\$(mktemp -d)
curl -fsSL "$BASE/$ZIP" -o "\$WORK/app.zip"
ditto -x -k "\$WORK/app.zip" "\$WORK"
pkill -x T3Recorder 2>/dev/null || true
sleep 0.5
mkdir -p ~/Applications
rm -rf "\$APP"
mv "\$WORK/T3 Recorder.app" "\$APP"
rm -rf "\$WORK"

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
echo "installed $ZIP, upload checked"
