import AVFoundation
import Foundation
import OSLog

private let log = Logger.make("AudioRec")

/// Records microphone audio at 16 kHz mono Float32, splitting into 30-second chunk files.
@MainActor
final class MobileAudioRecorder: ObservableObject {
    static let shared = MobileAudioRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Double = 0

    /// Called on the main actor when a 30-second (or final) chunk file is ready.
    var onChunkReady: ((URL, Int, Double) -> Void)?

    // MARK: - Constants

    private let targetSampleRate: Double = 16_000
    private let chunkDurationSeconds: Double = 30
    private var samplesPerChunk: Int { Int(targetSampleRate * chunkDurationSeconds) }

    // MARK: - Audio engine

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    // MARK: - Accumulation state (accessed only from audio callback queue)

    private let bufferQueue = DispatchQueue(label: "com.memgram.mobile.audioBuffer")
    private var accumulatedSamples: [Float] = []
    private var chunkIndex: Int = 0
    private var totalSamplesWritten: Int = 0

    // MARK: - Timer

    private var timer: Timer?
    private var recordingStartDate: Date?

    private init() {}

    // MARK: - Public API

    func start() throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatCreationFailed
        }

        guard let audioConverter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw RecorderError.converterCreationFailed
        }
        converter = audioConverter

        // Reset state
        bufferQueue.sync {
            accumulatedSamples.removeAll()
            chunkIndex = 0
            totalSamplesWritten = 0
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
        }

        try engine.start()

        isRecording = true
        recordingStartDate = Date()
        elapsedSeconds = 0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartDate else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }

        log.info("Recording started")
    }

    func stop() {
        guard isRecording else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false

        // Flush remaining samples as a partial chunk
        bufferQueue.sync {
            if !accumulatedSamples.isEmpty {
                let samples = accumulatedSamples
                let idx = chunkIndex
                let offset = Double(totalSamplesWritten) / targetSampleRate
                accumulatedSamples.removeAll()
                chunkIndex += 1
                totalSamplesWritten += samples.count

                if let url = Self.writeChunkFile(samples: samples) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onChunkReady?(url, idx, offset)
                    }
                }
            }
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("Recording stopped")
    }

    // MARK: - Audio buffer handling (background thread)

    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetSampleRate / buffer.format.sampleRate)
        ) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        var allConsumed = false
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            log.error("Conversion error: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let floatData = convertedBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))

        bufferQueue.sync { [weak self] in
            guard let self else { return }
            self.accumulatedSamples.append(contentsOf: samples)

            while self.accumulatedSamples.count >= self.samplesPerChunk {
                let chunkSamples = Array(self.accumulatedSamples.prefix(self.samplesPerChunk))
                self.accumulatedSamples.removeFirst(self.samplesPerChunk)

                let idx = self.chunkIndex
                let offset = Double(self.totalSamplesWritten) / self.targetSampleRate
                self.chunkIndex += 1
                self.totalSamplesWritten += chunkSamples.count

                if let url = Self.writeChunkFile(samples: chunkSamples) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onChunkReady?(url, idx, offset)
                    }
                }
            }
        }
    }

    // MARK: - File writing

    private static func writeChunkFile(samples: [Float]) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunk_\(UUID().uuidString).raw")
        do {
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            log.error("Failed to write chunk file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Errors

    enum RecorderError: LocalizedError {
        case formatCreationFailed
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .formatCreationFailed: return "Failed to create target audio format"
            case .converterCreationFailed: return "Failed to create audio converter"
            }
        }
    }
}
