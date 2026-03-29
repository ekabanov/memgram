import AVFoundation
import Combine
import OSLog
import WhisperKit

enum AudioChannel: String {
    case microphone = "microphone"
    case system     = "system"
    case unknown    = "unknown"
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
    private var whisperKit: WhisperKit?
    private let subject = PassthroughSubject<TranscriptSegment, Never>()
    private var accumulatedSeconds: Double = 0

    private struct PendingChunk {
        let samples: [Float]
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

    /// Load (and if needed download) the WhisperKit model, then warm up CoreML compilation.
    func prepare(modelName: String) async throws {
        log.info("Loading WhisperKit model: \(modelName, privacy: .public)")
        let wk = try await WhisperKit(model: modelName, verbose: false, logLevel: .none)
        self.whisperKit = wk
        log.info("WhisperKit loaded — triggering CoreML warm-up")

        // Run a silent 1-second dummy transcription to force CoreML compilation now,
        // rather than stalling the first real recording chunk.
        let silence = [Float](repeating: 0, count: 16000)
        _ = try? await wk.transcribe(audioArray: silence)
        log.info("WhisperKit ready — model: \(modelName, privacy: .public)")
        drainIfIdle()  // process any chunks that arrived before the model was ready
    }

    func reset() {
        accumulatedSeconds = 0
        pendingChunks.removeAll()
        isTranscribing = false
    }

    /// Called with each 30s stereo chunk from StereoMixer (left=mic, right=system).
    func transcribe(_ buffer: AVAudioPCMBuffer) {
        let leftEnergy  = channelRMS(buffer, channel: 0)
        let rightEnergy = channelRMS(buffer, channel: 1)
        guard let samples = toMonoFloats(buffer) else { return }

        let chunkStart = accumulatedSeconds
        accumulatedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate

        pendingChunks.append(PendingChunk(
            samples: samples, leftEnergy: leftEnergy,
            rightEnergy: rightEnergy, chunkStart: chunkStart
        ))
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard !isTranscribing, !pendingChunks.isEmpty else { return }
        guard let whisperKit else {
            // Model not loaded yet — chunks are buffered, will drain when prepare() completes
            return
        }
        let chunk = pendingChunks.removeFirst()
        isTranscribing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let options = DecodingOptions(
                    task: .transcribe,
                    language: nil,
                    temperature: 0.0,
                    skipSpecialTokens: true
                )
                let rms = chunk.samples.reduce(0.0) { $0 + $1 * $1 }
                let energy = sqrt(rms / Float(max(1, chunk.samples.count)))
                log.debug("Transcribing chunk — \(chunk.samples.count) samples (\(Int(Double(chunk.samples.count)/16000))s)")
                let results: [TranscriptionResult] = try await whisperKit.transcribe(
                    audioArray: chunk.samples,
                    decodeOptions: options
                )
                let allSegments = results.flatMap(\.segments)
                log.debug("Got \(results.count) result(s), \(allSegments.count) segment(s)")

                for result in results {
                    for seg in result.segments {
                        let text = seg.text.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { continue }

                        let startSec = chunk.chunkStart + Double(seg.start)
                        let endSec   = chunk.chunkStart + Double(seg.end)

                        let (speaker, channel) = self.determineSpeaker(
                            text: text,
                            leftEnergy: chunk.leftEnergy,
                            rightEnergy: chunk.rightEnergy
                        )
                        let cleanText = Self.stripDiarizationTags(text)
                        guard !cleanText.isEmpty else { continue }

                        self.subject.send(TranscriptSegment(
                            id: UUID(),
                            startSeconds: startSec,
                            endSeconds: endSec,
                            text: cleanText,
                            speaker: speaker,
                            channel: channel
                        ))
                    }
                }
            } catch {
                log.error("Chunk transcription failed: \(error)")
            }
            self.isTranscribing = false
            if self.pendingChunks.isEmpty {
                self.allChunksDoneSubject.send()
            } else {
                self.drainIfIdle()
            }
        }
    }

    // MARK: - Diarization

    private func determineSpeaker(text: String, leftEnergy: Float, rightEnergy: Float) -> (String, AudioChannel) {
        if text.contains("[SPEAKER_00]") { return ("You", .microphone) }
        if text.contains("[SPEAKER_01]") { return ("Remote", .system) }
        let threshold: Float = 1.2
        if leftEnergy > rightEnergy * threshold  { return ("You", .microphone) }
        if rightEnergy > leftEnergy * threshold  { return ("Remote", .system) }
        return leftEnergy >= rightEnergy ? ("You", .microphone) : ("Remote", .system)
    }

    private static func stripDiarizationTags(_ text: String) -> String {
        var result = text
        for tag in ["[SPEAKER_00]", "[SPEAKER_01]", "[SPEAKER_02]", "[SPEAKER_03]"] {
            result = result.replacingOccurrences(of: tag, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Audio helpers

    private func toMonoFloats(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        for ch in 0..<channelCount {
            for i in 0..<frames { mono[i] += channels[ch][i] }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frames { mono[i] *= scale }
        return mono
    }

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
