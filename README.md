<img src="assets/icon.svg" width="64" height="64" alt="">

# T3 Recorder

Show an agent what went wrong instead of describing it afterwards. A Mac menu bar app: press a key combination, show the problem and talk, press it again, paste into T3.

| Keys | What it does |
| --- | --- |
| ⌃⌥R | Start, and stop again. Records the screen the mouse is on, plus your voice. |
| ⌃⌥M | Mark mode on or off. While on (yellow rim), clicks and drags don't reach the app: a click highlights a spot, a drag frames an area. |
| ⌃⌥D | Drawing on or off. Then P pen, R rectangle, O circle, A arrow, T text, Z undo, C clear, Esc back to the normal mouse. |

Both ⌃⌥R and ⌃⌥M can be changed in the menu bar icon's menu.

When you stop, it transcribes on the Mac with Parakeet (no audio leaves it), picks screenshots (after clicks, marks, screen changes, and at least every 12 seconds of talking), uploads screenshots and video to the Mac mini and puts a timestamped text on the clipboard:

```
[00:03] CLICK: click at 50% across, 30% down in Safari "Settings"
[00:04] FRAME: /Users/stewie/share/recordings/r-20261030-190000/frames/f-00-04-0.jpg
[00:05] SAID: "now the page goes blank"
```

The clipboard holds text only, on purpose: when T3 gets text and images in one paste it keeps the images and drops the text. The agent opens the screenshot paths itself.

"Edit a recording" in the menu opens the editor: fix misheard words, remove lines, cut parts, add shapes and notes at a moment, record another section, then copy again. Edits never touch the raw clips in `~/Movies/T3 Recorder/`.

## Parts

- `Sources/RecorderCore`: timeline, cuts, screenshot choice, report text. No Apple media code, covered by `swift test`.
- `Sources/T3Recorder`: the app.
- `server/receive-recording`: forced command of the upload key on the mini (`~/house/bin/receive-recording`). The key can hand over a recording and do nothing else.
- `scripts/install-mac.sh`: first install on the MacBook from the newest release, run from the mini.
- Settings: `~/Library/Application Support/T3Recorder/config.json`.

## Updates

`scripts/release.sh X.Y.Z "what changed"` on the Mac mini ships a version: it builds, signs, publishes the feed and tags a GitHub release. The installed app (Sparkle) finds it at launch or within the hour and installs itself as soon as no recording or editor is open. The repo is private, so the feed and zip are served from a private link on the house (`~/share-public/t3-recorder`). Signing identity and update key live in `~/.config/t3-recorder`, with backups in the vault. Builds are not notarized: fine for Isaac's own Mac, not for handing the app to others.

Checks without hands: `T3Recorder --self-test out.png` runs the whole loop with a simulated mouse; `--capture-test`, `--import` and `--export` run single steps.
