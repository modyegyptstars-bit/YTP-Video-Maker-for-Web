#!/usr/bin/env bash
# Simple preview generator for YTP Video Maker (beta)
# Usage: bash generate-preview.sh input.mp4 config.json output_preview.mp4
# Requirements: ffmpeg, jq

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 input.mp4 config.json output_preview.mp4"
  exit 2
fi

INPUT="$1"
CONFIG="$2"
OUT="$3"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg not found. Please install ffmpeg."
  exit 3
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found. Please install jq."
  exit 3
fi

# Read globals
SCALE=$(jq -r '.global.preview_scale // 0.3' "$CONFIG")
FPS=$(jq -r '.global.preview_fps // 15' "$CONFIG")

# Temporary working file
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

WORK="$TMPDIR/work.mp4"
cp "$INPUT" "$WORK"

# Helper: maybe_apply filter — small deterministic randomization using seed if present
SEED=$(jq -r '.global.seed // 0' "$CONFIG")
if [ "$SEED" = "0" ]; then
  RAND() { awk "BEGIN{srand(); print int(rand()*1000000)}"; }
else
  RAND() { awk "BEGIN{srand('$SEED'); print int(rand()*1000000)}"; }
fi

# Build ffmpeg filtergraph in steps
VF=""
AF=""

# SCALE down for preview:
VF="${VF},scale=trunc(iw*${SCALE}):-2,fps=${FPS}"

# Invert
if [ "$(jq -r '.effects.invert.enabled' "$CONFIG")" = "true" ]; then
  P=$(jq -r '.effects.invert.probability' "$CONFIG")
  R=$(RAND)
  if [ "$(awk "BEGIN{print ($R/1000000) < $P}")" = "1" ]; then
    VF="${VF},negate"
    echo "[preview] Applying INVERT"
  fi
fi

# Mirror
if [ "$(jq -r '.effects.mirror.enabled' "$CONFIG")" = "true" ]; then
  P=$(jq -r '.effects.mirror.probability' "$CONFIG")
  R=$(RAND)
  if [ "$(awk "BEGIN{print ($R/1000000) < $P}")" = "1" ]; then
    VF="${VF},hflip"
    echo "[preview] Applying MIRROR"
  fi
fi

# Rainbow overlay (if provided)
if [ "$(jq -r '.effects.rainbow_overlay.enabled' "$CONFIG")" = "true" ]; then
  P=$(jq -r '.effects.rainbow_overlay.probability' "$CONFIG")
  R=$(RAND)
  if [ "$(awk "BEGIN{print ($R/1000000) < $P}")" = "1" ]; then
    OVERLAY=$(jq -r '.effects.rainbow_overlay.overlay_path' "$CONFIG")
    OPACITY=$(jq -r '.effects.rainbow_overlay.opacity // 0.6' "$CONFIG")
    if [ -f "$OVERLAY" ]; then
      # Use overlay with alpha: convert to format with alpha if needed
      VF="${VF},format=rgba [bg]; movie=${OVERLAY}, scale=iw*min(1,1),format=rgba [ov]; [bg][ov] overlay=0:0:format=auto"
      echo "[preview] Applying RAINBOW OVERLAY with opacity ${OPACITY}"
    else
      echo "[preview] Rainbow overlay file not found: ${OVERLAY} — skipping"
    fi
  fi
fi

# Reverse (video & audio)
if [ "$(jq -r '.effects.reverse.enabled' "$CONFIG")" = "true" ]; then
  P=$(jq -r '.effects.reverse.probability' "$CONFIG")
  R=$(RAND)
  if [ "$(awk "BEGIN{print ($R/1000000) < $P}")" = "1" ]; then
    # simple reverse for short previews: use reverse for video and areverse for audio
    VF="${VF},reverse"
    AF="${AF};[0:a]areverse"
    echo "[preview] Applying REVERSE"
  fi
fi

# Speed (approx using setpts/atempo)
if [ "$(jq -r '.effects.speed.enabled' "$CONFIG")" = "true" ]; then
  P=$(jq -r '.effects.speed.probability' "$CONFIG")
  R=$(RAND)
  if [ "$(awk "BEGIN{print ($R/1000000) < $P}")" = "1" ]; then
    MIN=$(jq -r '.effects.speed.min_factor' "$CONFIG")
    MAX=$(jq -r '.effects.speed.max_factor' "$CONFIG")
    # simple choice between min and max
    FACTOR=$(awk "BEGIN{srand(); print ($MIN + rand() * ($MAX - $MIN))}")
    VF="${VF},setpts=${FACTOR}*PTS"
    # atempo only supports 0.5-2.0; chain if needed (simple clamp)
    ATEMPO=$(awk "BEGIN{f=$FACTOR; if (f<0.125) f=0.125; if (f>8) f=8; print 1/f}")
    AF="${AF};[0:a]atempo=${ATEMPO}"
    echo "[preview] Applying SPEED factor ${FACTOR}"
  fi
fi

# Earrape
if [ "$(jq -r '.effects.earrape.enabled' "$CONFIG")" = "true" ]; then
  P=$(jq -r '.effects.earrape.probability' "$CONFIG")
  R=$(RAND)
  if [ "$(awk "BEGIN{print ($R/1000000) < $P}")" = "1" ]; then
    GAIN=$(jq -r '.effects.earrape.gain_db' "$CONFIG")
    AF="${AF};[0:a]volume=${GAIN}dB"
    echo "[preview] Applying EARRAPE +${GAIN}dB"
  fi
fi

# Meme injection (image overlay + audio)
if [ "$(jq -r '.effects.meme_injection.enabled' "$CONFIG")" = "true" ]; then
  P=$(jq -r '.effects.meme_injection.probability' "$CONFIG")
  R=$(RAND)
  if [ "$(awk "BEGIN{print ($R/1000000) < $P}")" = "1" ]; then
    IMG=$(jq -r '.effects.meme_injection.image_path' "$CONFIG")
    AUD=$(jq -r '.effects.meme_injection.audio_path' "$CONFIG")
    POS=$(jq -r '.effects.meme_injection.position // "10:10"' "$CONFIG")
    if [ -f "$IMG" ]; then
      VF="${VF},movie=${IMG} [m]; [0:v][m] overlay=${POS}"
      echo "[preview] Applying MEME IMAGE overlay ${IMG}"
    else
      echo "[preview] Meme image not found: ${IMG}"
    fi
    if [ -f "$AUD" ]; then
      # mix audio: the script will handle audio mixing below
      MEME_AUDIO="$AUD"
      echo "[preview] MEME audio will be mixed: ${AUD}"
    else
      MEME_AUDIO=""
    fi
  fi
fi

# Build ffmpeg command
# Input: original file. If MEME_AUDIO present, add it as second input for mixing.
FFCMD=(ffmpeg -y -i "$WORK")
if [ -n "${MEME_AUDIO:-}" ]; then
  FFCMD+=(-i "$MEME_AUDIO")
fi

# Video filter build: remove leading comma
VF_FILTER=$(echo "$VF" | sed 's/^,//')
if [ -n "$VF_FILTER" ]; then
  FFCMD+=(-vf "$VF_FILTER")
fi

# Audio filters
# If AF non-empty, transform ; separated into -af chain. For simplicity we handle the single combined -af or acomplex filter.
if [ -n "$AF" ]; then
  # remove leading semicolon
  AF_CLEAN=$(echo "$AF" | sed 's/^;//')
  # if MEME_AUDIO present, do a simple amix after applying AF_CLEAN to main audio
  if [ -n "${MEME_AUDIO:-}" ]; then
    # apply to first input, then amix with second
    FFCMD+=(-af "$AF_CLEAN,aresample=44100,volume=1")
    # then do amix using a complex filter (handled by -filter_complex)
    # fallback: just let ffmpeg concat second audio to a single stream using -shortest later
  else
    FFCMD+=(-af "$AF_CLEAN,aresample=44100")
  fi
fi

# Quick encoding settings for preview
FFCMD+=(-c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 96k -movflags +faststart)

# If meme audio present, run an additional mix step using filter_complex
if [ -n "${MEME_AUDIO:-}" ]; then
  # Filter-complex mixing: map video from 0:v, mix audio streams 0:a and 1:a
  echo "[preview] Mixing meme audio via filter_complex"
  ffmpeg -y -i "$WORK" -i "$MEME_AUDIO" -filter_complex "[0:v]${VF_FILTER}[vout];[0:a]aformat=fltp:44100:stereo[amain];[1:a]aformat=fltp:44100:stereo[ameme];[amain][ameme]amix=inputs=2:duration=shortest:dropout_transition=2[aout]" -map "[vout]" -map "[aout]" -c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 96k "$OUT"
else
  # Run the built ffmpeg command
  echo "[preview] Running ffmpeg:"
  echo "${FFCMD[*]} \"$OUT\""
  "${FFCMD[@]}" "$OUT"
fi

echo "[preview] Created ${OUT}"