```markdown
# YTP Video Maker for Web — Release 1.0

Release 1.0 of the YTP Video Maker scaffold. This project is a static site (GitHub Pages) UI that helps you assemble a JSON config and source list that a runner (local script or server) uses to drive ffmpeg and produce low-res previews fast.

Highlights in 1.0:
- Per-source "Shuffle Frames" — random frame reordering for jitter/chop effects.
- Per-source "Loop Frames" — short frame loops (2–12 frames) with repeat controls.
- Per-source effect exportable settings: speed factor, earrape gain, invert, mirror, reverse, etc.
- Runner script (generate-preview.sh) updated to apply per-source filters before concat and to support these new features.

Quick start (local):
1. Install ffmpeg, jq, and shuf (coreutils).
2. Export `config.json` from the UI and copy it along with referenced files to your local machine.
3. Run:
   ```
   bash generate-preview.sh config.json preview.mp4
   ```
4. Open preview.mp4 in the player (press 'p' or drop file in the player UI).

Notes:
- Frame-shuffle can be I/O heavy for long clips; prefer short segments for best interactivity (it's intended for previews).
- The runner is conservative and focuses on preview speed. For final renders, use higher CRF/bitrate settings or a more robust pipeline.
- Optional server runner can accept uploads (POST /render) — see assets/ffmpeg.js for the client helper.

License: MIT
```