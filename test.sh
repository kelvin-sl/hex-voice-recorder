#!/bin/sh
# End-to-end check without Hex: feed a hand-written event log to the recorder and check what it keeps.
# It opens the default microphone for about 4 seconds; the clips go to a temp folder and are deleted.
#   1. a 1.2 s dictation -> one FLAC + JSON (1.2 s + pre-roll + tail), losslessly decodable
#   2. a 0.1 s dictation -> dropped as a misfire
set -eu
cd "$(dirname "$0")"
T="$(mktemp -d)"; pid=""; trap 'kill -INT $pid 2>/dev/null || true; rm -rf "$T"' EXIT
LOG="$T/live.ndjson"; OUT="$T/out"; : > "$LOG"
./hex-voice-recorder --log "$LOG" --out "$OUT" 2> "$T/rec.log" & pid=$!
# Wait until the watcher has opened the log (it starts reading at the end), then let the ring fill.
i=0; until grep -q "watching" "$T/rec.log" 2>/dev/null; do i=$((i+1)); [ $i -gt 100 ] && { echo "FAIL: recorder never started"; exit 1; }; sleep 0.1; done
sleep 1
ms() { python3 -I -c 'import time; print(int(time.time()*1000))'; }
state() { echo "{\"kind\":\"state\",\"timestamp_ms\":$1,\"state\":\"$2\",\"device\":\"test-mic\"}" >> "$LOG"; }
a=$(ms); state "$a" dictating; sleep 1.2; state "$(ms)" transcribing; sleep 0.8
b=$(ms); state "$b" dictating; sleep 0.1; state "$(ms)" transcribing; sleep 0.8
kill -INT $pid; wait $pid 2>/dev/null || true
cat "$T/rec.log"
fail=0
[ -f "$OUT"/*/"$a.flac" ] && [ -f "$OUT"/*/"$a.json" ] || { echo "FAIL: clip $a missing"; fail=1; }
[ ! -e "$OUT"/*/"$b.flac" ] || { echo "FAIL: misfire $b was kept"; fail=1; }
if [ -f "$OUT"/*/"$a.flac" ]; then
  d=$(afinfo "$OUT"/*/"$a.flac" | awk -F': ' '/estimated duration/{print $2+0}')
  echo "clip duration ${d}s (expect ~2.0: 1.2 dictation + 0.5 pre-roll + 0.3 tail)"
  python3 -I -c "import sys; sys.exit(0 if 1.7 <= $d <= 2.4 else 1)" || { echo "FAIL: duration"; fail=1; }
  afconvert -f WAVE -d LEI24 "$OUT"/*/"$a.flac" "$T/a.wav" || { echo "FAIL: decode"; fail=1; }
  grep -q '"hex_device":"test-mic"' "$OUT"/*/"$a.json" || { echo "FAIL: json"; fail=1; }
fi
[ $fail = 0 ] && echo "PASS"
exit $fail
