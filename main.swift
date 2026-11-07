// hex-voice-recorder: while Hex is dictating, also record the microphone at its native rate.
//
// It reads Hex's event log (live.ndjson). A "dictating" state starts a WAV that begins
// PREROLL seconds early, taken from a 2 s in-memory ring buffer. The first state after it
// stops the recording TAIL seconds later. Nothing is written to disk outside a dictation.
// Each WAV gets a JSON sidecar with Hex's timestamps, so it can be paired later with History.
//
// Build: ./build.sh   Run: ./hex-voice-recorder [--out DIR]

import AVFoundation
import Foundation

let PREROLL = 0.5   // seconds of audio kept from before Hex's "dictating" event
let TAIL = 0.3      // seconds kept after Hex leaves "dictating"
let RING_SECONDS = 2.0
let home = FileManager.default.homeDirectoryForCurrentUser
let logURL = home.appendingPathComponent("Library/Application Support/hex/logs/live.ndjson")
var outDir = home.appendingPathComponent("VoiceData/hex-recorder")
if let i = CommandLine.arguments.firstIndex(of: "--out"), i + 1 < CommandLine.arguments.count {
    outDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
}

func log(_ s: String) { FileHandle.standardError.write(("[hex-rec] " + s + "\n").data(using: .utf8)!) }

// MARK: Recorder. All state is touched under `lock`: the audio thread and the log watcher share it.

final class Recorder {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private var rate = 0.0
    private var ring = [Float]()
    private var ringPos = 0          // next write index
    private var ringFilled = false
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var startedMs: Int64 = 0
    private var endedMs: Int64 = 0
    private var tailLeft = -1        // frames still to write after a stop; -1 = not stopping

    func start() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        rate = fmt.sampleRate
        ring = [Float](repeating: 0, count: Int(rate * RING_SECONDS))
        ringPos = 0; ringFilled = false
        log(String(format: "mic at %.0f Hz, %d ch", rate, fmt.channelCount))
        if rate < 44_100 { log("WARNING: below 44.1 kHz. This mic can't give you high-frequency audio (Bluetooth headsets are 16 kHz).") }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.feed(buf) }
        try engine.start()
    }

    func restart() {
        lock.lock(); closeFile(); lock.unlock()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        do { try start() } catch { log("restart failed: \(error)"); exit(1) }
    }

    // Audio thread: mono = channel 0.
    private func feed(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        lock.lock(); defer { lock.unlock() }
        for i in 0..<n {
            ring[ringPos] = ch[i]
            ringPos += 1
            if ringPos == ring.count { ringPos = 0; ringFilled = true }
        }
        guard let f = file else { return }
        let take = tailLeft >= 0 ? min(n, tailLeft) : n
        if take > 0, let out = mono(from: ch, count: take) { try? f.write(from: out) }
        if tailLeft >= 0 {
            tailLeft -= take
            if tailLeft <= 0 { closeFile() }
        }
    }

    private func mono(from p: UnsafePointer<Float>, count: Int) -> AVAudioPCMBuffer? {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        b.frameLength = AVAudioFrameCount(count)
        b.floatChannelData![0].update(from: p, count: count)
        return b
    }

    // Watcher thread.
    func begin(ms: Int64) {
        lock.lock(); defer { lock.unlock() }
        if file != nil { if tailLeft >= 0 { closeFile() } else { return } }   // already recording this one
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let dir = outDir.appendingPathComponent(day.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ms).wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        else { log("can't open \(url.path)"); return }
        // Pre-roll: the last PREROLL seconds of the ring, oldest first.
        let have = ringFilled ? ring.count : ringPos
        let pre = min(have, Int(rate * PREROLL))
        var tmp = [Float](repeating: 0, count: pre)
        for i in 0..<pre { tmp[i] = ring[(ringPos - pre + i + ring.count) % ring.count] }
        if pre > 0, let b = tmp.withUnsafeBufferPointer({ mono(from: $0.baseAddress!, count: pre) }) { try? f.write(from: b) }
        file = f; fileURL = url; startedMs = ms; endedMs = 0; tailLeft = -1
    }

    func end(ms: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard file != nil, tailLeft < 0 else { return }
        endedMs = ms
        tailLeft = Int(rate * TAIL)
    }

    // Caller holds the lock.
    private func closeFile() {
        guard let url = fileURL else { return }
        file = nil; fileURL = nil; tailLeft = -1      // releasing AVAudioFile finalizes the WAV header
        let meta: [String: Any] = ["hex_started_ms": startedMs, "hex_ended_ms": endedMs, "sample_rate": rate,
                                   "channels": 1, "bit_depth": 24, "preroll_s": PREROLL, "tail_s": TAIL]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
            try? d.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
        log("saved \(url.lastPathComponent)")
    }
}

// MARK: Log watcher. Tails live.ndjson; reopens it if Hex rotates or recreates the file.

final class Watcher {
    private let q = DispatchQueue(label: "hex-rec.watch")
    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var partial = Data()
    private var dictating = false
    let onStart: (Int64) -> Void, onStop: (Int64) -> Void

    init(onStart: @escaping (Int64) -> Void, onStop: @escaping (Int64) -> Void) { self.onStart = onStart; self.onStop = onStop }

    func open() {
        guard let h = FileHandle(forReadingAtPath: logURL.path) else {
            log("waiting for \(logURL.path)")
            q.asyncAfter(deadline: .now() + 2) { self.open() }; return
        }
        h.seekToEndOfFile()
        handle = h; partial.removeAll()
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: h.fileDescriptor, eventMask: [.extend, .write, .delete, .rename], queue: q)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if s.data.contains(.delete) || s.data.contains(.rename) { self.reopen(); return }
            self.read()
        }
        s.resume(); source = s
        log("watching \(logURL.path)")
    }

    private func reopen() {
        source?.cancel(); source = nil
        try? handle?.close(); handle = nil
        q.asyncAfter(deadline: .now() + 0.5) { self.open() }
    }

    private func read() {
        guard let h = handle else { return }
        partial.append(h.readDataToEndOfFile())
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
            partial.removeSubrange(partial.startIndex...nl)
            process(line: line)
        }
    }

    // Only state lines matter: {"kind":"state","timestamp_ms":…,"state":"dictating",…}
    private func process(line: String) {
        guard line.contains("\"kind\":\"state\""), let ms = Self.timestamp(line) else { return }
        let isDictating = line.contains("\"state\":\"dictating\"")
        if isDictating && !dictating { onStart(ms) }
        if !isDictating && dictating { onStop(ms) }
        dictating = isDictating
    }

    static func timestamp(_ line: String) -> Int64? {
        guard let r = line.range(of: "\"timestamp_ms\":") else { return nil }
        return Int64(line[r.upperBound...].prefix(while: { $0.isNumber }))
    }
}

// MARK: Main

let recorder = Recorder()
do { try recorder.start() } catch { log("can't start the microphone: \(error)"); exit(1) }
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
    log("audio device changed; restarting"); recorder.restart()
}
let watcher = Watcher(onStart: { recorder.begin(ms: $0) }, onStop: { recorder.end(ms: $0) })
watcher.open()
log("writing to \(outDir.path)")
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
let stopSignals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { recorder.end(ms: Int64(Date().timeIntervalSince1970 * 1000)); DispatchQueue.main.asyncAfter(deadline: .now() + TAIL + 0.2) { exit(0) } }
    s.resume(); return s
}
RunLoop.main.run()
