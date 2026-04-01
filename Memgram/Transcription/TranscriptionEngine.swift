import AVFoundation
import Combine
import OSLog

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? { "Transcription model is not loaded" }
}

struct TranscriptSegment: Identifiable {
    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    var speaker: String
    var channel: AudioChannel
}

final class TranscriptionEngine {

    private let log = Logger.make("Transcription")
    private var transcriber: (any TranscriberProtocol)?
    private let subject = PassthroughSubject<TranscriptSegment, Never>()
    private var accumulatedSeconds: Double = 0

    private struct PendingChunk {
        let buffer: AVAudioPCMBuffer
        let leftEnergy: Float
        let rightEnergy: Float
        let chunkStart: Double
    }
    private var pendingChunks: [PendingChunk] = []
    private var isTranscribing = false

    private let allChunksDoneSubject = PassthroughSubject<Void, Never>()

    var allChunksDonePublisher: AnyPublisher<Void, Never> {
        allChunksDoneSubject.eraseToAnyPublisher()
    }

    var isIdle: Bool { !isTranscribing && pendingChunks.isEmpty }

    var segmentPublisher: AnyPublisher<TranscriptSegment, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Load the active backend model. modelName is used only for Whisper;
    /// Parakeet uses a fixed v3 model internally.
    func prepare(modelName: String) async throws {
        guard transcriber == nil else { return }
        #if os(macOS)
        let backend = await MainActor.run { TranscriptionBackendManager.shared.selectedBackend }
        switch backend {
        case .whisper:
            let t = WhisperTranscriber()
            try await t.prepare()
            transcriber = t
        case .parakeet:
            let t = ParakeetTranscriber()
            try await t.prepare()
            transcriber = t
        }
        #else
        // iOS always uses Whisper (FluidAudio/Parakeet is macOS-only)
        let t = WhisperTranscriber()
        try await t.prepare()
        transcriber = t
        #endif
        drainIfIdle()
    }

    func reset() {
        accumulatedSeconds = 0
        pendingChunks.removeAll()
        isTranscribing = false
    }

    /// Discard the loaded transcriber so the next prepare() call loads the active backend.
    func resetTranscriber() {
        transcriber = nil
        Task { @MainActor in
            WhisperModelManager.shared.isWhisperReady = false
            WhisperModelManager.shared.isWhisperDownloading = false
            TranscriptionBackendManager.shared.isParakeetReady = false
            TranscriptionBackendManager.shared.isLoading = false
        }
    }

    /// Called with each stereo chunk from StereoMixer (left=mic, right=system).
    func transcribe(_ buffer: AVAudioPCMBuffer) {
        let leftEnergy  = channelRMS(buffer, channel: 0)
        let rightEnergy = channelRMS(buffer, channel: 1)
        let chunkStart = accumulatedSeconds
        accumulatedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate

        pendingChunks.append(PendingChunk(
            buffer: buffer, leftEnergy: leftEnergy,
            rightEnergy: rightEnergy, chunkStart: chunkStart
        ))
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard !isTranscribing, !pendingChunks.isEmpty else { return }
        guard let transcriber, transcriber.isReady else { return }
        let chunk = pendingChunks.removeFirst()
        isTranscribing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let segments = try await transcriber.transcribeStereoBuffer(
                    chunk.buffer,
                    leftEnergy: chunk.leftEnergy,
                    rightEnergy: chunk.rightEnergy,
                    chunkStart: chunk.chunkStart
                )
                for segment in segments { self.subject.send(segment) }
            } catch {
                self.log.error("Chunk transcription failed: \(error)")
            }
            self.isTranscribing = false
            if self.pendingChunks.isEmpty {
                self.allChunksDoneSubject.send()
            } else {
                self.drainIfIdle()
            }
        }
    }

    // MARK: - Raw Audio Transcription (iPhone remote chunks via RemoteMeetingProcessor)

    func transcribeRawAudio(samples: [Float], meetingId: String, offsetSeconds: Double) async throws -> [MeetingSegment] {
        guard let transcriber else { throw TranscriptionError.modelNotLoaded }
        return try await transcriber.transcribeRawAudio(
            samples: samples, meetingId: meetingId, offsetSeconds: offsetSeconds)
    }

    // MARK: - Audio helpers

    private func channelRMS(_ buffer: AVAudioPCMBuffer, channel: Int) -> Float {
        guard let channels = buffer.floatChannelData,
              channel < Int(buffer.format.channelCount) else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let ptr = channels[channel]
        var sum: Float = 0
        for i in 0..<frames { sum += ptr[i] * ptr[i] }
        return sqrt(sum / Float(frames))
    }
}
