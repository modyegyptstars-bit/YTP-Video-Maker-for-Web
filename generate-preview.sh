#!/usr/bin/env bash
# generate-preview.sh — Release 1.0 runner
# Adds per-source shuffle-frames and loop-frames handling.
# Usage: bash generate-preview.sh config.json output_preview.mp4
# Requirements: ffmpeg, jq, shuf (coreutils), awk, sort, seq, cp
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 config.json output_preview.mp4"
  exit 2
fi

CONFIG="$1"
OUT="$2"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found"; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 4; }
command -v shuf >/dev/null 2>&1 || { echo "shuf not found. Install coreutils."; exit 5; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SCALE=$(jq -r '.global.preview_scale // 0.3' "$CONFIG")
FPS=$(jq -r '.global.preview_fps // 15' "$CONFIG")

echo "[preview] release=1.0 scale=${SCALE} fps=${FPS}"

COUNT=$(jq '.sources | length' "$CONFIG")
if [ "$COUNT" -eq 0 ]; then
  echo "No sources listed in $CONFIG" >&2
  exit 6
fi

SEGMENTS=()
for i in $(seq 0 $((COUNT-1))); do
  src=$(jq -c ".sources[$i]" "$CONFIG")
  path=$(jq -r ".sources[$i].path" "$CONFIG")
  typ=$(jq -r ".sources[$i].type" "$CONFIG")
  id=$(jq -r ".sources[$i].id // \"s$((i+1))\"" "$CONFIG")
  start=$(jq -r ".sources[$i].start // empty" "$CONFIG" || echo "")
  end=$(jq -r ".sources[$i].end // empty" "$CONFIG" || echo "")
  duration=$(jq -r ".sources[$i].duration // empty" "$CONFIG" || echo "")
  # per-source flags
  shuffle=$(jq -r ".sources[$i].effects.shuffle_frames // false" "$CONFIG")
  shuffle_intensity=$(jq -r ".sources[$i].effects.shuffle_intensity // 1.0" "$CONFIG")
  loop_enabled=$(jq -r ".sources[$i].effects.loop_frames // false" "$CONFIG")
  loop_len=$(jq -r ".sources[$i].effects.loop_length_frames // 4" "$CONFIG")
  loop_repeats=$(jq -r ".sources[$i].effects.loop_repeats // 2" "$CONFIG")
  invert=$(jq -r ".sources[$i].effects.invert // false" "$CONFIG")
  mirror=$(jq -r ".sources[$i].effects.mirror // false" "$CONFIG")
  reverse=$(jq -r ".sources[$i].effects.reverse // false" "$CONFIG")
  speed_enabled=$(jq -r ".sources[$i].effects.speed // false" "$CONFIG")
  speed_factor=$(jq -r ".sources[$i].effects.speed_factor // empty" "$CONFIG" || echo "")
  earrape=$(jq -r ".sources[$i].effects.earrape // false" "$CONFIG")
  earrape_gain=$(jq -r ".sources[$i].effects.earrape_gain_db // empty" "$CONFIG" || echo "")

  if [ ! -f "$path" ]; then
    echo "[preview][${id}] missing file: $path — skipping"
    continue
  fi

  outseg="$TMPDIR/seg_${id}.mp4"
  echo "[preview][${id}] preparing ($typ) -> $outseg"

  # Base filters
  VF="scale=trunc(iw*${SCALE}):-2,fps=${FPS}"
  AF=""

  # basic per-source transforms
  [ "$invert" = "true" ] && VF="${VF},negate" && echo "[preview][${id}] invert"
  [ "$mirror" = "true" ] && VF="${VF},hflip" && echo "[preview][${id}] mirror"
  if [ "$reverse" = "true" ]; then
    VF="${VF},reverse"
    AF="${AF};areverse"
    echo "[preview][${id}] reverse"
  fi

  if [ "$speed_enabled" = "true" ]; then
    if [ -n "$speed_factor" ] && [ "$speed_factor" != "null" ]; then
      FACTOR="$speed_factor"
    else
      FACTOR=1.0
    fi
    VF="${VF},setpts=${FACTOR}*PTS"
    inv=$(awk "BEGIN{f=${FACTOR}; if(f==0) f=1; print 1/f}")
    # build atempo chain
    atempo=""
    remain=$inv
    while awk "BEGIN{exit !($remain > 2.01)}"; do
      atempo="${atempo}atempo=2.0,"
      remain=$(awk "BEGIN{print $remain/2.0}")
    done
    atempo="${atempo}atempo=$(awk "BEGIN{if($remain<0.5) print 0.5; else if($remain>2) print 2; else printf(\"%.6f\", $remain)}")"
    AF="${AF};${atempo}"
    echo "[preview][${id}] speed factor ${FACTOR}"
  fi

  if [ "$earrape" = "true" ]; then
    if [ -n "$earrape_gain" ] && [ "$earrape_gain" != "null" ]; then
      GAIN="$earrape_gain"
    else
      GAIN=12
    fi
    AF="${AF};volume=${GAIN}dB"
    echo "[preview][${id}] earrape +${GAIN}dB"
  fi

  # ==== loop-frames: implement short frame-precise loops BEFORE concat
  if [ "$loop_enabled" = "true" ] && [ "$typ" = "video" ]; then
    # We'll attempt to use the loop filter: select a short range, then loop that block N times and concat
    # Approach: extract the desired small clip around the start (or beginning) into a small temp video, apply loop filter using trim/select and loop.
    # We approximate: if clip start provided use it, else 0.
    start_opt="$start"
    if [ -z "$start_opt" ]; then start_opt=0; fi
    # compute the duration of loop block in seconds from number of frames
    block_dur=$(awk "BEGIN{print ${loop_len} / ${FPS}}")
    temp_clip="$TMPDIR/${id}_loop_block.mp4"
    # extract block
    ffmpeg -y -ss "$start_opt" -i "$path" -t "$block_dur" -vf "scale=trunc(iw*${SCALE}):-2,fps=${FPS}" -c:v libx264 -preset veryfast -crf 24 -an "$temp_clip" < /dev/null
    # create looped block using concat: repeat block N times into a single file
    loop_concat_list="$TMPDIR/${id}_loop_list.txt"
    : > "$loop_concat_list"
    for r in $(seq 1 $loop_repeats); do echo "file '$temp_clip'" >> "$loop_concat_list"; done
    looped_block="$TMPDIR/${id}_looped.mp4"
    ffmpeg -y -f concat -safe 0 -i "$loop_concat_list" -c:v libx264 -preset veryfast -crf 24 -an "$looped_block" < /dev/null
    # Now take the original segment (apply trimming if any) and replace the first block duration with the looped block
    # Approach: extract pre (before start_opt), post (after start_opt+block_dur), and concat: pre + looped_block + post
    pre_segment="$TMPDIR/${id}_pre.mp4"
    post_segment="$TMPDIR/${id}_post.mp4"
    if awk "BEGIN{exit !( $start_opt > 0 )}"; then
      ffmpeg -y -ss 0 -i "$path" -t "$start_opt" -vf "scale=trunc(iw*${SCALE}):-2,fps=${FPS}" -c:v libx264 -preset veryfast -crf 24 -an "$pre_segment" < /dev/null
    else
      # empty pre -> create a tiny blank
      : > /dev/null
    fi
    end_after=$(awk "BEGIN{print $start_opt + $block_dur}")
    ffmpeg -y -ss "$end_after" -i "$path" -vf "scale=trunc(iw*${SCALE}):-2,fps=${FPS}" -c:v libx264 -preset veryfast -crf 24 -an "$post_segment" < /dev/null
    # build the concat list for final seg
    loop_final_list="$TMPDIR/${id}_loop_final.txt"
    : > "$loop_final_list"
    [ -s "$pre_segment" ] && echo "file '$pre_segment'" >> "$loop_final_list"
    echo "file '$looped_block'" >> "$loop_final_list"
    [ -s "$post_segment" ] && echo "file '$post_segment'" >> "$loop_final_list"
    ffmpeg -y -f concat -safe 0 -i "$loop_final_list" -c:v libx264 -preset veryfast -crf 24 -an "$outseg" < /dev/null
    # Note: audio will be reattached below (we'll mix/re-encode to keep preview simple)
    echo "[preview][${id}] applied loop frames (len=${loop_len}, repeats=${loop_repeats})"
    SEGMENTS+=("$outseg")
    continue
  fi

  # ==== shuffle-frames: extract frames, randomize order, re-encode (works for short segments)
  if [ "$shuffle" = "true" ] && [ "$typ" = "video" ]; then
    frames_dir="$TMPDIR/frames_${id}"
    mkdir -p "$frames_dir"
    ss_arg=()
    to_arg=()
    if [ -n "$start" ]; then ss_arg+=("-ss" "$start"); fi
    if [ -n "$end" ] && [ -n "$start" ]; then
      dur=$(awk "BEGIN{print $end - $start}")
      to_arg+=("-t" "$dur")
    elif [ -n "$end" ] && [ -z "$start" ]; then
      to_arg+=("-to" "$end")
    fi
    # extract frames to PNG sequence
    ffmpeg -y "${ss_arg[@]}" -i "$path" "${to_arg[@]}" -vf "scale=trunc(iw*${SCALE}):-2,fps=${FPS}" -vsync vfr "$frames_dir/frame_%06d.png" < /dev/null
    count=$(ls -1 "$frames_dir"/frame_*.png 2>/dev/null | wc -l)
    if [ "$count" -eq 0 ]; then
      echo "[preview][${id}] no frames extracted, skipping shuffle"
    else
      # shuffle intensity: fraction of frames to permute; 1.0 = full shuffle
      intensity=$(awk "BEGIN{v=$shuffle_intensity; if(v<=0) v=0; if(v>1) v=1; print v}")
      num_to_shuffle=$(awk "BEGIN{printf \"%d\", ($count * $intensity)}")
      if [ "$num_to_shuffle" -le 1 ]; then num_to_shuffle=$count; fi
      # pick indices to shuffle
      all_frames=( "$frames_dir"/frame_*.png )
      # generate order: leave first N-n shuffled frames in place to reduce randomness if intensity < 1
      # simplest approach: fully shuffle when intensity near 1, otherwise shuffle subset
      shuffled_dir="$TMPDIR/frames_${id}_shuf"
      mkdir -p "$shuffled_dir"
      if awk "BEGIN{exit !($intensity >= 0.99)}"; then
        # full shuffle
        ls "$frames_dir"/frame_*.png | shuf | nl -v1 -w6 -s '' | while read n f; do cp "$f" "$shuffled_dir/frm_$(printf %06d $n).png"; done
      else
        # partial shuffle: keep prefix, shuffle the rest
        keep=$(awk "BEGIN{printf \"%d\", $count*(1-$intensity)}")
        if [ "$keep" -lt 0 ]; then keep=0; fi
        # copy the keep prefix
        idx=0
        for f in "${all_frames[@]}"; do
          idx=$((idx+1))
          if [ "$idx" -le "$keep" ]; then
            cp "$f" "$shuffled_dir/frm_$(printf %06d $idx).png"
          else
            echo "$f" >> "$shuffled_dir/order.txt"
          fi
        done
        if [ -f "$shuffled_dir/order.txt" ]; then
          shuf "$shuffled_dir/order.txt" | nl -v$((keep+1)) -w6 -s '' | while read n f; do cp "$f" "$shuffled_dir/frm_$(printf %06d $n).png"; done
          rm -f "$shuffled_dir/order.txt"
        fi
      fi
      # re-encode shuffled frames into video
      ffmpeg -y -framerate "$FPS" -i "$shuffled_dir/frm_%06d.png" -c:v libx264 -preset veryfast -crf 24 -pix_fmt yuv420p -r "$FPS" -an "$outseg" < /dev/null
      echo "[preview][${id}] applied shuffle_frames (intensity=${shuffle_intensity})"
      SEGMENTS+=("$outseg")
      continue
    fi
  fi

  # Default handling when no special pre-segment processing required
  case "$typ" in
    video)
      ss_arg=()
      to_arg=()
      if [ -n "$start" ]; then ss_arg+=("-ss" "$start"); fi
      if [ -n "$end" ] && [ -n "$start" ]; then
        dur=$(awk "BEGIN{print $end - $start}")
        to_arg+=("-t" "$dur")
      elif [ -n "$end" ] && [ -z "$start" ]; then
        to_arg+=("-to" "$end")
      fi
      AF_CLEAN=$(echo "$AF" | sed 's/^;//')
      if [ -n "$AF_CLEAN" ]; then
        ffmpeg -y "${ss_arg[@]}" -i "$path" "${to_arg[@]}" -vf "$VF" -af "$AF_CLEAN,aresample=44100" -c:v libx264 -preset veryfast -crf 24 -c:a aac -b:a 96k -movflags +faststart "$outseg" < /dev/null
      else
        ffmpeg -y "${ss_arg[@]}" -i "$path" "${to_arg[@]}" -vf "$VF" -c:v libx264 -preset veryfast -crf 24 -c:a aac -b:a 96k -movflags +faststart "$outseg" < /dev/null
      fi
      ;;
    audio)
      # convert audio to a brief video segment
      tmpaud="$TMPDIR/${id}.aac"
      ffmpeg -y -i "$path" -c:a aac -b:a 96k -ac 2 "$tmpaud" < /dev/null
      if [ -n "$duration" ]; then duropt="$duration"; else duropt=3; fi
      AF_CLEAN=$(echo "$AF" | sed 's/^;//')
      if [ -n "$AF_CLEAN" ]; then
        ffmpeg -y -f lavfi -i color=size=320x240:duration="$duropt":rate="$FPS":color=black -i "$tmpaud" -shortest -af "$AF_CLEAN,aresample=44100" -c:v libx264 -preset veryfast -crf 24 -c:a aac -b:a 96k "$outseg" < /dev/null
      else
        ffmpeg -y -f lavfi -i color=size=320x240:duration="$duropt":rate="$FPS":color=black -i "$tmpaud" -shortest -c:v libx264 -preset veryfast -crf 24 -c:a aac -b:a 96k "$outseg" < /dev/null
      fi
      ;;
    image)
      if [ -z "$duration" ] || [ "$duration" = "null" ]; then duration=2; fi
      AF_CLEAN=$(echo "$AF" | sed 's/^;//')
      if [ -n "$AF_CLEAN" ]; then
        ffmpeg -y -loop 1 -i "$path" -t "$duration" -vf "$VF" -af "$AF_CLEAN,aresample=44100" -c:v libx264 -preset veryfast -crf 24 -pix_fmt yuv420p -c:a aac -b:a 96k "$outseg" < /dev/null
      else
        ffmpeg -y -loop 1 -i "$path" -t "$duration" -vf "$VF" -c:v libx264 -preset veryfast -crf 24 -pix_fmt yuv420p -c:a aac -b:a 96k "$outseg" < /dev/null
      fi
      ;;
    *)
      echo "[preview][${id}] unknown type ${typ}, skipping"
      continue
      ;;
  esac

  if [ -f "$outseg" ]; then
    SEGMENTS+=("$outseg")
    echo "[preview][${id}] segment ready"
  fi
done

if [ "${#SEGMENTS[@]}" -eq 0 ]; then
  echo "[preview] no segments prepared" >&2
  exit 7
fi

CONCATLIST="$TMPDIR/concat_list.txt"
: > "$CONCATLIST"
for s in "${SEGMENTS[@]}"; do
  echo "file '$s'" >> "$CONCATLIST"
done

CONCATED="$TMPDIR/concat.mp4"
ffmpeg -y -f concat -safe 0 -i "$CONCATLIST" -c:v libx264 -preset veryfast -crf 26 -c:a aac -b:a 96k "$CONCATED" < /dev/null
echo "[preview] concatenated -> $CONCATED"

# Apply global effects (as before)
VF_GLOBAL=""
AF_GLOBAL=""

apply_if_enabled() {
  name="$1"
  jq -r ".effects.${name}.enabled // false" "$CONFIG"
}

if [ "$(apply_if_enabled invert)" = "true" ]; then VF_GLOBAL="${VF_GLOBAL},negate"; fi
if [ "$(apply_if_enabled mirror)" = "true" ]; then VF_GLOBAL="${VF_GLOBAL},hflip"; fi
if [ "$(apply_if_enabled reverse)" = "true" ]; then VF_GLOBAL="${VF_GLOBAL},reverse"; AF_GLOBAL="${AF_GLOBAL};areverse"; fi
if [ "$(jq -r '.effects.rainbow_overlay.enabled // false' "$CONFIG")" = "true" ]; then
  OVERLAY=$(jq -r '.effects.rainbow_overlay.overlay_path // ""' "$CONFIG")
  if [ -n "$OVERLAY" ] && [ -f "$OVERLAY" ]; then
    VF_GLOBAL="${VF_GLOBAL},format=rgba [bg]; movie=${OVERLAY}, format=rgba [ov]; [bg][ov] overlay=0:0:format=auto"
  fi
fi

VF_FILTER=$(echo "$VF_GLOBAL" | sed 's/^,//')
AF_CLEAN=$(echo "$AF_GLOBAL" | sed 's/^;//')

if [ -n "$VF_FILTER" ] && [ -n "$AF_CLEAN" ]; then
  ffmpeg -y -i "$CONCATED" -vf "$VF_FILTER" -af "$AF_CLEAN,aresample=44100" -c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 96k "$OUT" < /dev/null
elif [ -n "$VF_FILTER" ]; then
  ffmpeg -y -i "$CONCATED" -vf "$VF_FILTER" -c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 96k "$OUT" < /dev/null
elif [ -n "$AF_CLEAN" ]; then
  ffmpeg -y -i "$CONCATED" -af "$AF_CLEAN,aresample=44100" -c:v libx264 -preset veryfast -crf 28 -c:a aac -b:a 96k "$OUT" < /dev/null
else
  ffmpeg -y -i "$CONCATED" -c:v libx264 -preset veryfast -crf 26 -c:a aac -b:a 96k "$OUT" < /dev/null
fi

echo "[preview] Created ${OUT}"