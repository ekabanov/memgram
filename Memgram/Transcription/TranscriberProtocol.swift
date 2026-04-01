import AVFoundation
import Foundation

enum AudioChannel: String {
    case microphone = "microphone"
    case system     = "system"
    case unknown    = "unknown"
}

/// The two available transcription backends.
enum TranscriptionBackend: String, CaseIterable, Identifiable {
    case whisper  = "whisper"
    case parakeet = "parakeet"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:  return "Whisper (WhisperKit)"
        case .parakeet: return "Parakeet (FluidAudio)"
        }
    }

    var description: String {
        switch self {
        case .whisper:
            return "OpenAI Whisper — 100+ languages, runs on GPU via Metal."
        case .parakeet:
            return "NVIDIA Parakeet TDT — 25 European languages, ~10× faster, zero hallucinations on silence. Runs on Neural Engine."
        }
    }
}

/// Common interface for transcription backends.
/// Both WhisperTranscriber and ParakeetTranscriber conform to this.
protocol TranscriberProtocol: AnyObject {
    /// True when the model is fully loaded and ready to transcribe.
    var isReady: Bool { get }

    /// Download (if needed), load, and warm up the model.
    func prepare() async throws

    /// Transcribe a stereo 16 kHz Float32 buffer (L=mic, R=system).
    /// Returns segments with speaker attribution.
    func transcribeStereoBuffer(
        _ buffer: AVAudioPCMBuffer,
        leftEnergy: Float,
        rightEnergy: Float,
        chunkStart: Double
    ) async throws -> [TranscriptSegment]

    /// Transcribe a mono 16 kHz Float32 array (remote audio from iPhone).
    func transcribeRawAudio(
        samples: [Float],
        meetingId: String,
        offsetSeconds: Double
    ) async throws -> [MeetingSegment]
}
