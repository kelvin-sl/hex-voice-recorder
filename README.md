# hex-voice-recorder

Keep a high-quality copy of your own voice every time you dictate with [Hex](https://github.com/anomalyco/hex).

Hex is a local voice-dictation app: hold a key, speak, and the text is pasted. It
resamples your microphone to 16 kHz mono for its speech model, and that's the only
audio it can keep. This tool runs next to Hex and records the same speech at your
microphone's native rate (for example 48 kHz / 24-bit). The recordings pile up as you
work, as raw material for training a voice model of your own voice later.

Hex is not modified. This project is not affiliated with Hex or Anomaly.

## How it works

```
mic ──┬──> Hex                 dictates and pastes as usual; History keeps the text
      └──> hex-voice-recorder  keeps the last 2 s in memory (nothing on disk)
                               Hex enters "dictating"  -> open a WAV, write 0.5 s pre-roll
                               Hex leaves "dictating"  -> record 0.3 s more, close
```

- The trigger is Hex's event log, `~/Library/Application Support/hex/logs/live.ndjson`.
  Only its `"kind":"state"` lines are read (`dictating` and whatever follows it).
- Output is `~/VoiceData/hex-recorder/<date>/<hex_started_ms>.wav` (24-bit mono, at the mic's
  rate). Next to it a `.json` holds Hex's start and end timestamps, so each clip can be
  paired with its transcript from Hex's History.
- Nothing is written outside a dictation. About 10–13 MB of memory while running.
- The recorder restarts on an audio device change. It warns when the mic is below 44.1 kHz:
  Bluetooth headset mics are 16 kHz and gain nothing over Hex's own copy.

## Use

```sh
./build.sh                 # one native binary, no dependencies (Swift, AVFoundation)
./hex-voice-recorder       # Ctrl-C to stop; [--out DIR] to change the folder
```

On first run macOS asks for microphone access for your terminal.

Set the mic to 48 kHz in Audio MIDI Setup and make it the default input. The recorder
records the system default input, so Hex should use the same mic.

### Archive as FLAC, unpack for training

```sh
./pack.sh      # WAV -> FLAC in place; a WAV is deleted only after its FLAC decodes back to identical PCM
./unpack.sh    # FLAC -> 24-bit WAV into ~/VoiceData/hex-recorder-wav (the archive is untouched)
```

FLAC is lossless; in testing it was about 65% of the WAV size.

## Limits

- `live.ndjson` is Hex's internal log, not a public API. A Hex release that changes its
  format breaks the trigger until this is updated.
- Tested on macOS 27.2 (Apple silicon) with Hex 3.3.0 and a 16 kHz Bluetooth mic.
  WAV length matched Hex's dictation length plus the 0.8 s of padding. A 48 kHz USB mic
  has not been tested yet.
- macOS only.

### Build note

Some Command Line Tools installs ship a stale `usr/include/swift/module.modulemap` that
redefines `SwiftBridging` and breaks every `import Foundation`. `build.sh` detects it and
hides it with a VFS overlay for this build only; no system file is changed.

## License

MIT
