import AVFoundation
import OSLog
import WhisperKit

/// WhisperKit-based implementation of TranscriberProtocol.
final class WhisperTranscriber: TranscriberProtocol {

    private let log = Logger.make("Transcription")
    private var whisperKit: WhisperKit?

    var isReady: Bool { whisperKit != nil }

    func prepare() async throws {
        guard whisperKit == nil else {
            log.debug("WhisperKit already loaded, skipping prepare")
            return
        }
        let modelName = await MainActor.run { WhisperModelManager.shared.selectedModel.whisperKitName }
        log.info("Loading WhisperKit model: \(modelName)")
        await MainActor.run { WhisperModelManager.shared.isWhisperDownloading = true }
        let wk = try await WhisperKit(model: modelName, verbose: false, logLevel: .none)
        self.whisperKit = wk
        log.info("WhisperKit loaded — triggering CoreML warm-up")
        let silence = [Float](repeating: 0, count: 16000)
        _ = try? await wk.transcribe(audioArray: silence)
        log.info("WhisperKit ready — model: \(modelName)")
        await MainActor.run {
            WhisperModelManager.shared.isWhisperDownloading = false
            WhisperModelManager.shared.isWhisperReady = true
        }
    }

    func transcribeStereoBuffer(
        _ buffer: AVAudioPCMBuffer,
        leftEnergy: Float,
        rightEnergy: Float,
        chunkStart: Double
    ) async throws -> [TranscriptSegment] {
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        guard let samples = selectDominantChannel(buffer, leftEnergy: leftEnergy, rightEnergy: rightEnergy) else { return [] }

        let options = DecodingOptions(task: .transcribe, language: nil,
                                      temperature: 0.0, skipSpecialTokens: true)
        log.debug("Transcribing chunk — \(samples.count) samples (\(Int(Double(samples.count)/16000))s)")
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples, decodeOptions: options)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let text = seg.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let startSec = chunkStart + Double(seg.start)
                let endSec   = chunkStart + Double(seg.end)
                let (speaker, channel) = determineSpeaker(
                    text: text, leftEnergy: leftEnergy, rightEnergy: rightEnergy)
                let cleanText = Self.stripDiarizationTags(text)
                guard !cleanText.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    id: UUID(), startSeconds: startSec, endSeconds: endSec,
                    text: cleanText, speaker: speaker, channel: channel))
            }
        }
        return segments
    }

    func transcribeRawAudio(
        samples: [Float],
        meetingId: String,
        offsetSeconds: Double
    ) async throws -> [MeetingSegment] {
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        let options = DecodingOptions(task: .transcribe, temperature: 0.0, skipSpecialTokens: true)
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples, decodeOptions: options)

        var segments: [MeetingSegment] = []
        for result in results {
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(MeetingSegment(
                    id: UUID().uuidString, meetingId: meetingId,
                    speaker: "Remote", channel: "microphone",
                    startSeconds: offsetSeconds + Double(segment.start),
                    endSeconds: offsetSeconds + Double(segment.end),
                    text: text, ckSystemFields: nil))
            }
        }
        log.info("Transcribed \(segments.count) segments from \(samples.count) samples at offset \(offsetSeconds)s")
        return segments
    }

    // MARK: - Helpers

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

}
