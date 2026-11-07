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
                               Hex enters "dictating"  -> open a FLAC, write 0.5 s pre-roll
                               Hex leaves "dictating"  -> record 0.3 s more, close
```

- The trigger is Hex's event log, `~/Library/Application Support/hex/logs/live.ndjson`.
  Only its `"kind":"state"` lines are read (`dictating` and whatever follows it).
- Output is `~/VoiceData/hex-recorder/<date>/<hex_started_ms>.flac`: 24-bit mono at the mic's
  rate, lossless (in testing it decodes to the same PCM a WAV would hold, at about 60–65% of the size).
- Each clip has a `.json` sidecar for pairing with Hex's History:
  `hex_started_ms`, `hex_ended_ms`, `hex_device` (Hex's mic), `recorder_device` (this tool's mic),
  `sample_rate`, `channels`, `bit_depth`, `preroll_s`, `tail_s`.
- A clip is dropped when the mic sent no audio, or when Hex's dictation was shorter than
  0.3 s (a misfire).
- Nothing is written outside a dictation. About 10–17 MB of memory while running.
- It follows the system default input: when the default changes (or a device reconfigures),
  it restarts on the new mic. It warns when the mic is below 44.1 kHz, and when Hex and the
  recorder are on different mics.

## Use

```sh
./build.sh                 # one native binary, no dependencies (Swift, AVFoundation, CoreAudio)
./hex-voice-recorder       # Ctrl-C to stop; [--out DIR] to change the folder
./test.sh                  # end-to-end check with a fake event log (opens the mic for ~4 s)
```

On first run macOS asks for microphone access for your terminal.

Set the mic to 48 kHz in Audio MIDI Setup, make it the default input, and pick the same mic
in Hex's settings.

Mics that won't give you more than Hex already keeps:
- **Bluetooth mics** (AirPods, headsets, a wireless lav's transmitter paired directly) run
  at 16 kHz. Bluetooth carries a mic only in the hands-free call profile.
- **Some headsets over USB** still expose a 16 kHz mic. One tested headset exposed a USB input
  that delivered no audio at all; the recorder now drops those clips.

Use a USB microphone, a USB audio interface, or a wireless kit's USB receiver.

### Unpack for training

```sh
./unpack.sh    # FLAC -> 24-bit WAV into ~/VoiceData/hex-recorder-wav (the archive is untouched)
./pack.sh      # only for WAVs from older versions: WAV -> FLAC, deleting a WAV only after
               # its FLAC decodes back to identical PCM
```

## Limits

- `live.ndjson` is Hex's internal log, not a public API. A Hex release that changes its
  format breaks the trigger until this is updated.
- Tested on macOS 27.2 (Apple silicon) with Hex 3.3.0 and 16 kHz Bluetooth mics: clip length
  matched Hex's dictation plus 0.8 s of padding. A 48 kHz USB mic has not been tested yet.
- macOS only.

### Build note

Some Command Line Tools installs ship a stale `usr/include/swift/module.modulemap` that
redefines `SwiftBridging` and breaks every `import Foundation`. `build.sh` detects it and
hides it with a VFS overlay for this build only; no system file is changed.

## License

MIT
