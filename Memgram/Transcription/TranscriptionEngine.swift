import AVFoundation
import Combine
import SwiftWhisper

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

    private var whisper: Whisper?
    private let subject = PassthroughSubject<TranscriptSegment, Never>()
    private var accumulatedSeconds: Double = 0

    // Serial queue for pending chunks — prevents instanceBusy by processing one at a time.
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

    func prepare(modelURL: URL) throws {
        let w = Whisper(fromFileURL: modelURL)
        let isEnglishOnly = modelURL.lastPathComponent.contains(".en.")
        if isEnglishOnly {
            w.params.language = .english
        } else {
            w.params.language = .auto
        }
        w.params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        w.params.no_context = false
        w.params.suppress_blank = true
        self.whisper = w
        print("[TranscriptionEngine] Loaded model: \(modelURL.lastPathComponent) | language: \(isEnglishOnly ? "english" : "auto") | threads: \(w.params.n_threads)")
    }

    func reset() {
        accumulatedSeconds = 0
        pendingChunks.removeAll()
        isTranscribing = false
    }

    /// Called with each 30s stereo chunk from StereoMixer (left=mic, right=system).
    /// Enqueues the chunk; transcription runs serially so Whisper is never called while busy.
    func transcribe(_ buffer: AVAudioPCMBuffer) {
        guard whisper != nil else { return }

        let leftEnergy  = channelRMS(buffer, channel: 0)
        let rightEnergy = channelRMS(buffer, channel: 1)
        guard let samples = toMonoFloats(buffer) else { return }

        let chunkStart = accumulatedSeconds
        accumulatedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate

        let chunk = PendingChunk(samples: samples, leftEnergy: leftEnergy,
                                 rightEnergy: rightEnergy, chunkStart: chunkStart)
        pendingChunks.append(chunk)
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard !isTranscribing, !pendingChunks.isEmpty, let whisper else { return }
        let chunk = pendingChunks.removeFirst()
        isTranscribing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let segments = try await whisper.transcribe(audioFrames: chunk.samples)
                for seg in segments {
                    let text = seg.text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }

                    let startSec = chunk.chunkStart + Double(seg.startTime) / 1000.0
                    let endSec   = chunk.chunkStart + Double(seg.endTime)   / 1000.0

                    let (speaker, channel) = self.determineSpeaker(
                        text: text,
                        leftEnergy: chunk.leftEnergy,
                        rightEnergy: chunk.rightEnergy
                    )
                    let cleanText = Self.stripDiarizationTags(text)
                    guard !cleanText.isEmpty else { continue }

                    let segment = TranscriptSegment(
                        id: UUID(),
                        startSeconds: startSec,
                        endSeconds: endSec,
                        text: cleanText,
                        speaker: speaker,
                        channel: channel
                    )
                    self.subject.send(segment)
                }
            } catch {
                // Non-fatal — skip chunk
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
