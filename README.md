<img src="assets/icon.svg" width="64" height="64" alt="">

# T3 Recorder

Show an agent what went wrong instead of describing it afterwards. A Mac menu bar app: press a key combination, show the problem and talk, press it again, paste into T3.

| Keys | What it does |
| --- | --- |
| ⌃⌥R | Start, and stop again. Records the screen the mouse is on, plus your voice. |
| ⌃⌥M | Mark mode on or off. While on (yellow rim), clicks and drags don't reach the app: a click highlights a spot, a drag frames an area. |
| ⌃⌥D | Drawing on or off. Then P pen, R rectangle, O circle, A arrow, T text, Z undo, C clear, Esc back to the normal mouse. |

Both ⌃⌥R and ⌃⌥M can be changed in the menu bar icon's menu.

When you stop, it transcribes on the Mac with Parakeet (no audio leaves it) and picks screenshots: after clicks, marks and screen changes, and at least every 12 seconds of talking. Then the clipboard holds `report.txt`, the screenshots and `recording.mp4` (when under 50 MB). Paste into T3, add a word if you like, send.

```
[00:03] CLICK: click at 50% across, 30% down in Safari "Settings"
[00:04] FRAME: f-00-04-0.jpg
[00:05] SAID: "now the page goes blank"
```

They travel as files because T3 drops pasted text when images come along, and because T3's own connection then carries everything: no upload, no server, it works wherever T3 works.

"Edit a recording" in the menu opens the editor: fix misheard words, remove lines, cut parts, add shapes and notes at a moment, record another section, then copy again. Edits never touch the raw clips in `~/Library/Application Support/T3Recorder/Recordings/`.

## Install

Download the zip from the [latest release](https://github.com/isaaclins/t3-recorder/releases/latest), move `T3 Recorder.app` to Applications, then clear the download flag once (the app isn't notarized):

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

`scripts/release.sh X.Y.Z "what changed"` on the Mac mini ships a version: it builds, signs, publishes the feed and tags a GitHub release. The installed app (Sparkle) finds it at launch or within the hour and installs itself as soon as no recording or editor is open. The repo is private, so the feed and zip are served from a private link on the house (`~/share-public/t3-recorder`). Signing identity and update key live in `~/.config/t3-recorder`, with backups in the vault. Builds are not notarized: fine for Isaac's own Mac, not for handing the app to others.

Checks without hands: `T3Recorder --self-test out.png` runs the whole loop with a simulated mouse; `--capture-test`, `--import` and `--export` run single steps.
