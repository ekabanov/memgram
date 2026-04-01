#if os(macOS)
import AVFoundation
import FluidAudio
import OSLog

/// FluidAudio Parakeet TDT-based implementation of TranscriberProtocol.
/// Uses the Neural Engine via CoreML for fast, low-hallucination transcription.
final class ParakeetTranscriber: TranscriberProtocol {

    private let log = Logger.make("ParakeetTranscriber")
    private var asrManager: AsrManager?

    var isReady: Bool { asrManager != nil }

    // MARK: - Prepare

    func prepare() async throws {
        guard asrManager == nil else {
            log.debug("Parakeet already loaded, skipping prepare")
            return
        }

        await MainActor.run { TranscriptionBackendManager.shared.isLoading = true }

        log.info("Downloading / loading Parakeet TDT 0.6B v3 models...")
        let models = try await AsrModels.downloadAndLoad(version: .v3)

        let manager = AsrManager()
        try await manager.initialize(models: models)

        self.asrManager = manager
        log.info("Parakeet ASR manager ready")

        await MainActor.run {
            TranscriptionBackendManager.shared.isLoading = false
            TranscriptionBackendManager.shared.isParakeetReady = true
        }
    }

    // MARK: - Stereo Buffer Transcription

    func transcribeStereoBuffer(
        _ buffer: AVAudioPCMBuffer,
        leftEnergy: Float,
        rightEnergy: Float,
        chunkStart: Double
    ) async throws -> [TranscriptSegment] {
        guard let asrManager else { throw TranscriptionError.modelNotLoaded }
        guard let monoSamples = toMonoFloats(buffer) else { return [] }

        log.debug("Transcribing chunk — \(monoSamples.count) samples (\(Int(Double(monoSamples.count) / 16000))s)")
        let result = try await asrManager.transcribe(monoSamples, source: .microphone)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        // Build segments from token timings if available, otherwise one segment for the whole chunk
        if let timings = result.tokenTimings, !timings.isEmpty {
            return buildSegmentsFromTimings(
                timings,
                fullText: text,
                chunkStart: chunkStart,
                leftEnergy: leftEnergy,
                rightEnergy: rightEnergy
            )
        }

        // Fallback: single segment for the entire transcription
        let (speaker, channel) = determineSpeaker(leftEnergy: leftEnergy, rightEnergy: rightEnergy)
        return [TranscriptSegment(
            id: UUID(),
            startSeconds: chunkStart,
            endSeconds: chunkStart + result.duration,
            text: text,
            speaker: speaker,
            channel: channel
        )]
    }

    // MARK: - Raw Audio Transcription

    func transcribeRawAudio(
        samples: [Float],
        meetingId: String,
        offsetSeconds: Double
    ) async throws -> [MeetingSegment] {
        guard let asrManager else { throw TranscriptionError.modelNotLoaded }

        let result = try await asrManager.transcribe(samples, source: .microphone)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var segments: [MeetingSegment] = []

        if let timings = result.tokenTimings, !timings.isEmpty {
            // Group contiguous tokens into sentence-like segments
            let grouped = groupTimingsIntoSegments(timings)
            for group in grouped {
                let segText = group.map(\.token).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segText.isEmpty else { continue }
                guard let first = group.first, let last = group.last else { continue }
                segments.append(MeetingSegment(
                    id: UUID().uuidString,
                    meetingId: meetingId,
                    speaker: "Remote",
                    channel: "microphone",
                    startSeconds: offsetSeconds + first.startTime,
                    endSeconds: offsetSeconds + last.endTime,
                    text: segText,
                    ckSystemFields: nil
                ))
            }
        } else {
            segments.append(MeetingSegment(
                id: UUID().uuidString,
                meetingId: meetingId,
                speaker: "Remote",
                channel: "microphone",
                startSeconds: offsetSeconds,
                endSeconds: offsetSeconds + result.duration,
                text: text,
                ckSystemFields: nil
            ))
        }

        log.info("Transcribed \(segments.count) segments from \(samples.count) samples at offset \(offsetSeconds)s")
        return segments
    }

    // MARK: - Private Helpers

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

    private func determineSpeaker(leftEnergy: Float, rightEnergy: Float) -> (String, AudioChannel) {
        let threshold: Float = 1.2
        if leftEnergy > rightEnergy * threshold  { return ("You", .microphone) }
        if rightEnergy > leftEnergy * threshold  { return ("Remote", .system) }
        return leftEnergy >= rightEnergy ? ("You", .microphone) : ("Remote", .system)
    }

    /// Build TranscriptSegments from token timings, grouping tokens into natural segments.
    private func buildSegmentsFromTimings(
        _ timings: [TokenTiming],
        fullText: String,
        chunkStart: Double,
        leftEnergy: Float,
        rightEnergy: Float
    ) -> [TranscriptSegment] {
        let grouped = groupTimingsIntoSegments(timings)
        let (speaker, channel) = determineSpeaker(leftEnergy: leftEnergy, rightEnergy: rightEnergy)

        var segments: [TranscriptSegment] = []
        for group in grouped {
            let segText = group.map(\.token).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segText.isEmpty else { continue }
            guard let first = group.first, let last = group.last else { continue }
            segments.append(TranscriptSegment(
                id: UUID(),
                startSeconds: chunkStart + first.startTime,
                endSeconds: chunkStart + last.endTime,
                text: segText,
                speaker: speaker,
                channel: channel
            ))
        }
        return segments
    }

    /// Group token timings into segments by splitting on gaps > 0.8s or sentence-ending punctuation.
    private func groupTimingsIntoSegments(_ timings: [TokenTiming]) -> [[TokenTiming]] {
        guard !timings.isEmpty else { return [] }

        var groups: [[TokenTiming]] = []
        var current: [TokenTiming] = [timings[0]]

        for i in 1..<timings.count {
            let gap = timings[i].startTime - timings[i - 1].endTime
            let prevToken = timings[i - 1].token.trimmingCharacters(in: .whitespaces)
            let isSentenceEnd = prevToken.hasSuffix(".") || prevToken.hasSuffix("?") || prevToken.hasSuffix("!")

            if gap > 0.8 || isSentenceEnd {
                groups.append(current)
                current = [timings[i]]
            } else {
                current.append(timings[i])
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
#endif
