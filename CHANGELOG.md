```markdown
# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2025-09-07
### Added
- Release 1.0: first stable release of the YTP Video Maker for Web scaffold.
- Per-source "Shuffle Frames" — extract and randomly reorder frames for jitter/chop effects.
- Per-source "Loop Frames" — short frame-precise loops (2–12 frames) with configurable repeats.
- Per-source effect controls exported to config.json (speed factor, earrape gain, invert/mirror toggles).
- Runner improvements: generate-preview.sh now applies per-source filters before concatenation.
- UI improvements: Release 1.0 banner, updated sample config, and export flow.

### Changed
- Player JS and ffmpeg client helper updated to integrate better with a local runner.
- README updated with release notes and deployment steps.

### Fixed
- Various small fixes for preview encoding and concat compatibility in the runner script.

```