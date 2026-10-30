#!/usr/bin/env bash
# Automation t3-recorder-install: installs as soon as the MacBook is on, tells Isaac there, then ends itself.
set -uo pipefail
cd "$(dirname "$0")/.."
scripts/install-mac.sh
rc=$?
[ "$rc" -eq 2 ] && exit 0
[ "$rc" -eq 0 ] || exit "$rc"
ssh mac "osascript -e 'display notification \"Press Control-Option-R to record. Allow the permissions it asks for.\" with title \"T3 Recorder is ready\"'" || true
~/house/bin/auto done t3-recorder-install
