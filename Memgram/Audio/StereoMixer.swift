import AVFoundation
import Combine

/// Receives mono 16kHz Float32 buffers from mic (Left) and system audio (Right),
/// accumulates them into 30-second stereo chunks, and emits each chunk.
final class StereoMixer {

    static let chunkDuration: Double = 30.0  // seconds
    static let sampleRate: Double = 16000.0
    static let framesPerChunk = Int(chunkDuration * sampleRate)  // 480 000

    private var micAccumulator: [Float] = []
    private var sysAccumulator: [Float] = []
    private let lock = NSLock()

    private var micCancellable: AnyCancellable?
    private var sysCancellable: AnyCancellable?
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()

    // Published level values (0.0–1.0) for the UI meter — updated at 10Hz via timer
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    // Atomic staging vars written from audio thread, read by timer on main thread
    private var _latestMicLevel: Float = 0
    private var _latestSysLevel: Float = 0
    private var levelTimer: Timer?

    var chunkPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        subject.eraseToAnyPublisher()
    }

    func connect(mic: AnyPublisher<AVAudioPCMBuffer, Never>,
                 system: AnyPublisher<AVAudioPCMBuffer, Never>) {
        micCancellable = mic.receive(on: DispatchQueue.global(qos: .userInitiated)).sink { [weak self] buf in
            self?.appendMic(buf)
        }
        sysCancellable = system.receive(on: DispatchQueue.global(qos: .userInitiated)).sink { [weak self] buf in
            self?.appendSystem(buf)
        }
        // Poll levels at 10Hz instead of dispatching per-buffer
        DispatchQueue.main.async {
            self.levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let m = self._latestMicLevel
                let s = self._latestSysLevel
                self.lock.unlock()
                self.micLevel = m
                self.sysLevel = s
            }
        }
    }

    /// Flush any remaining partial audio (< 30 s) as a final chunk, then disconnect.
    func flushAndDisconnect() {
        micCancellable = nil
        sysCancellable = nil
        DispatchQueue.main.async { self.levelTimer?.invalidate(); self.levelTimer = nil }
        lock.lock()
        let mic = micAccumulator
        let sys = sysAccumulator
        micAccumulator.removeAll()
        sysAccumulator.removeAll()
        lock.unlock()

        let count = max(mic.count, sys.count)
        guard count > 0 else { return }
        let paddedMic = mic.count < count ? mic + [Float](repeating: 0, count: count - mic.count) : mic
        let paddedSys = sys.count < count ? sys + [Float](repeating: 0, count: count - sys.count) : sys
        guard let chunk = buildStereoBuffer(left: paddedMic, right: paddedSys) else { return }
        subject.send(chunk)
    }

    func disconnect() {
        micCancellable = nil
        sysCancellable = nil
        DispatchQueue.main.async { self.levelTimer?.invalidate(); self.levelTimer = nil }
        lock.lock()
        micAccumulator.removeAll()
        sysAccumulator.removeAll()
        lock.unlock()
    }

    // MARK: - Private

    private func appendMic(_ buf: AVAudioPCMBuffer) {
        // Mix all channels down to mono before computing level and accumulating
        guard let channelData = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        let channelCount = Int(buf.format.channelCount)
        var mixed = [Float](repeating: 0, count: frames)
        for ch in 0..<channelCount {
            let src = UnsafeBufferPointer(start: channelData[ch], count: frames)
            for i in 0..<frames { mixed[i] += src[i] }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frames { mixed[i] *= scale }

        let level = rmsLevel(mixed)
        lock.lock()
        _latestMicLevel = level
        micAccumulator.append(contentsOf: mixed)
        let shouldFlush = micAccumulator.count >= Self.framesPerChunk && sysAccumulator.count >= Self.framesPerChunk
        lock.unlock()

        if shouldFlush { flushChunk() }
    }

    private func appendSystem(_ buf: AVAudioPCMBuffer) {
        guard let data = buf.floatChannelData?[0] else { return }
        let frames = Int(buf.frameLength)
        let samples = Array(UnsafeBufferPointer(start: data, count: frames))
        lock.lock()
        _latestSysLevel = rmsLevel(samples)
        sysAccumulator.append(contentsOf: samples)
        let shouldFlush = micAccumulator.count >= Self.framesPerChunk && sysAccumulator.count >= Self.framesPerChunk
        lock.unlock()

        if shouldFlush { flushChunk() }
    }

    private func flushChunk() {
        lock.lock()
        guard micAccumulator.count >= Self.framesPerChunk,
              sysAccumulator.count >= Self.framesPerChunk else {
            lock.unlock()
            return
        }
        let micSlice = Array(micAccumulator.prefix(Self.framesPerChunk))
        let sysSlice = Array(sysAccumulator.prefix(Self.framesPerChunk))
        micAccumulator.removeFirst(Self.framesPerChunk)
        sysAccumulator.removeFirst(Self.framesPerChunk)
        lock.unlock()

        guard let chunk = buildStereoBuffer(left: micSlice, right: sysSlice) else { return }
        subject.send(chunk)
        saveChunkToDisk(chunk)
    }

    private func buildStereoBuffer(left: [Float], right: [Float]) -> AVAudioPCMBuffer? {
        let stereoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(left.count)
        guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount

        guard let channels = buf.floatChannelData else { return nil }
        left.withUnsafeBufferPointer { ptr in
            channels[0].initialize(from: ptr.baseAddress!, count: left.count)
        }
        right.withUnsafeBufferPointer { ptr in
            channels[1].initialize(from: ptr.baseAddress!, count: right.count)
        }
        return buf
    }

    private func saveChunkToDisk(_ buf: AVAudioPCMBuffer) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("memgram")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("chunk_\(Date().timeIntervalSince1970).caf")
        guard let audioFile = try? AVAudioFile(forWriting: file, settings: buf.format.settings) else { return }
        try? audioFile.write(from: buf)
    }

    private func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        let rms = sqrt(sumSquares / Float(samples.count))
        // Apply log scaling so quiet signals are visible (typical speech RMS ~0.003-0.03)
        guard rms > 0 else { return 0 }
        let db = 20.0 * log10(rms)       // e.g. -50 dB for rms=0.003
        let normalized = (db + 60.0) / 60.0  // map -60..0 dB → 0..1
        return max(0, min(1, normalized))
    }
}
