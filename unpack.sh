#!/bin/sh
# FLAC -> 24-bit WAV for training. Writes WAVs into OUT (default: a copy tree next to DIR);
# the FLAC archive is left untouched.
# Usage: ./unpack.sh [DIR] [OUT]
set -eu
DIR="${1:-$HOME/VoiceData/hex-recorder}"
OUT="${2:-$HOME/VoiceData/hex-recorder-wav}"
n=0
for flac in $(find "$DIR" -name '*.flac' | sort); do
  rel="${flac#$DIR/}"; dest="$OUT/${rel%.flac}.wav"
  mkdir -p "$(dirname "$dest")"
  afconvert -f WAVE -d LEI24 "$flac" "$dest"
  [ -f "${flac%.flac}.json" ] && cp "${flac%.flac}.json" "${dest%.wav}.json"
  n=$((n+1))
done
echo "unpacked $n files to $OUT"
