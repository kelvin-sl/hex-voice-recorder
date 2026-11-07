#!/bin/sh
# WAV -> FLAC (lossless), in place. A WAV is deleted only after its FLAC decodes back to
# byte-identical PCM. Only finished recordings (the .json sidecar exists) are touched, so a
# file the recorder is still writing is skipped.
# Usage: ./pack.sh [DIR]   (default ~/VoiceData/hex-recorder)
set -u
DIR="${1:-$HOME/VoiceData/hex-recorder}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
packed=0; failed=0; before=0; after=0
for wav in $(find "$DIR" -name '*.wav' | sort); do
  base="${wav%.wav}"
  [ -f "$base.json" ] || { echo "skip (still recording): $wav"; continue; }
  afconvert -f flac -d flac "$wav" "$base.flac" || { echo "FAIL convert: $wav"; failed=$((failed+1)); continue; }
  afconvert -f WAVE -d LEI24 "$base.flac" "$TMP/check.wav"
  if python3 -I "$(dirname "$0")/samepcm.py" "$wav" "$TMP/check.wav"; then
    before=$((before + $(stat -f %z "$wav"))); after=$((after + $(stat -f %z "$base.flac")))
    rm "$wav"; packed=$((packed+1))
  else
    echo "FAIL verify, kept WAV: $wav"; rm -f "$base.flac"; failed=$((failed+1))
  fi
done
echo "packed $packed, failed $failed: $((before/1024)) KB -> $((after/1024)) KB"
