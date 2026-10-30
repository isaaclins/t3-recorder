<img src="assets/icon.svg" width="64" height="64" alt="">

# T3 Recorder

Show an agent what went wrong instead of describing it afterwards. A Mac menu bar app: press a key combination, show the problem and talk, press it again, paste into T3.

| Keys | What it does |
| --- | --- |
| ⌃⌥R | Start, and stop again. Records the screen the mouse is on, plus your voice. |
| ⌃⌥M | Mark mode on or off. While on (yellow rim), clicks and drags don't reach the app: a click highlights a spot, a drag frames an area. |
| ⌃⌥D | Drawing on or off. Then P pen, R rectangle, O circle, A arrow, T text, Z undo, C clear, Esc back to the normal mouse. |

Both ⌃⌥R and ⌃⌥M can be changed in the menu bar icon's menu.

When you stop, it transcribes on the Mac with Parakeet (no audio leaves it) and picks screenshots: after clicks, marks and screen changes, and at least every 12 seconds of talking. Then the clipboard holds `report.txt` and the screenshots. Paste into T3, add a word if you like, send.

The video stays on your Mac, because about 17 MB a minute is a lot to send when the report and screenshots usually say it all. The report tells the agent it isn't attached. When one recording does need it, press "Add video" on the message that appears after stopping, or "Copy with video" in the editor (up to 50 MB).

```
[00:03] CLICK: click at 50% across, 30% down in Safari "Settings"
[00:04] FRAME: f-00-04-0.jpg
[00:05] SAID: "now the page goes blank"
```

They travel as files because T3 drops pasted text when images come along, and because T3's own connection then carries everything: no upload, no server, it works wherever T3 works.

"Edit a recording" in the menu opens the editor: fix misheard words, remove lines, cut parts, add shapes and notes at a moment, record another section, then copy again, with or without the video. Edits never touch the raw clips in `~/Library/Application Support/T3Recorder/Recordings/`.

## Install

Download the DMG from the [latest release](https://github.com/isaaclins/t3-recorder/releases/latest) and drag `T3 Recorder.app` to Applications. `SHA256SUMS.txt` on the release has the checksums. The app isn't notarized, so clear the download flag once:

```
xattr -dr com.apple.quarantine "/Applications/T3 Recorder.app"
```

Open it and allow Screen Recording, Microphone and Accessibility. Updates install themselves.

## Parts

- `Sources/RecorderCore`: timeline, cuts, screenshot choice, report text. No Apple media code, covered by `swift test`.
- `Sources/T3Recorder`: the app.
- `scripts/bundle.sh`, `scripts/release.sh`: build, sign, ship.
- Settings: `~/Library/Application Support/T3Recorder/config.json`.

## Updates

`scripts/release.sh X.Y.Z "what changed"` on the Mac mini ships a version: it builds, signs and publishes a GitHub release with the DMG, zip, checksums and Sparkle feed. The installed app (Sparkle) reads `releases/latest/download/appcast.xml` at launch and every hour, and installs itself as soon as no recording or editor is open. Updates only install when signed with the private update key, which lives in `~/.config/t3-recorder` with the signing identity (backups in the vault). Builds are not notarized.

Checks without hands: `T3Recorder --self-test out.png` runs the whole loop with a simulated mouse; `--capture-test`, `--import` and `--export` run single steps.
