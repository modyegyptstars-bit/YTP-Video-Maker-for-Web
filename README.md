```markdown
# YTP Video Maker for Web (Beta)

A GitHub Pages front-end scaffold for assembling YouTube Poop (YTP) style effects, producing quick ffmpeg-driven previews.

This repository contains:
- A static interface (index.html) describing usage and generating a config.json.
- A sample config file (config.sample.json).
- A bash preview generator (generate-preview.sh) that applies a small pipeline of ffmpeg operations based on config.
- Minimal stylesheet and license.

Important: GitHub Pages cannot run ffmpeg. Use the provided script locally or build a small server to accept the config and run ffmpeg on a machine where ffmpeg is installed.

Quick start:
1. Install ffmpeg and jq.
2. Copy `config.sample.json` to `config.json` and tweak settings.
3. Run:
   ```bash
   bash generate-preview.sh input.mp4 config.json preview.mp4
   ```
4. Open `preview.mp4` in a player or serve the directory and press "p" on the page to open the preview (if preview.mp4 exists).

Extending:
- Add more effects by editing the script or implement a proper Node/Express or Flask runner that interprets the config with more sophisticated pipelines.
- Improve the UI to create/validate config JSON and upload overlays/meme files.

License: MIT
```