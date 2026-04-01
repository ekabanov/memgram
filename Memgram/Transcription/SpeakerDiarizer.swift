#if os(macOS)
import AVFoundation
import Accelerate
import FluidAudio
import OSLog

private let log = Logger.make("Diarizer")

@available(macOS 14.0, *)
final class SpeakerDiarizer {

    // MARK: - State

    private var models: SortformerModels?
    private var micSamples: [Float] = []
    private var sysSamples: [Float] = []

    /// Per-chunk energy log for echo suppression decisions.
    private(set) var energyLog: [(startSec: Double, endSec: Double, micEnergy: Float, sysEnergy: Float)] = []

    private let sampleRate: Double
    private let lock = NSLock()

    // MARK: - Init

    init(sampleRate: Double = 16_000.0) {
        self.sampleRate = sampleRate
    }

    // MARK: - Model Lifecycle

    /// Downloads and compiles Sortformer models from HuggingFace.
    func prepare() async throws {
        log.info("Loading Sortformer models (balancedV2_1)…")
        let loaded = try await SortformerModels.loadFromHuggingFace(config: .balancedV2_1)
        models = loaded
        log.info("Sortformer models ready (compiled in \(String(format: "%.1f", loaded.compilationDuration))s)")
    }

    /// Clears accumulated audio and energy log, keeping models loaded.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        micSamples.removeAll(keepingCapacity: false)
        sysSamples.removeAll(keepingCapacity: false)
        energyLog.removeAll(keepingCapacity: false)
    }

    // MARK: - Audio Accumulation

    /// Extracts left (mic) and right (system) channels from a stereo buffer,
    /// accumulates them, and logs per-chunk energy.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount >= 2, frameCount > 0 else { return }

        let leftPtr = floatData[0]
        let rightPtr = floatData[1]

        let left = Array(UnsafeBufferPointer(start: leftPtr, count: frameCount))
        let right = Array(UnsafeBufferPointer(start: rightPtr, count: frameCount))

        let micE = rms(left)
        let sysE = rms(right)

        lock.lock()
        defer { lock.unlock() }

        let startSec = Double(micSamples.count) / sampleRate
        micSamples.append(contentsOf: left)
        sysSamples.append(contentsOf: right)
        let endSec = Double(micSamples.count) / sampleRate

        energyLog.append((startSec: startSec, endSec: endSec, micEnergy: micE, sysEnergy: sysE))
    }

    // MARK: - Diarization

    /// Runs Sortformer diarization on both channels and resolves each transcript
    /// segment to a speaker label.
    ///
    /// - Parameter segments: Transcript segments from WhisperKit/Parakeet.
    /// - Returns: A map of segment UUID string to resolved speaker label.
    func runAndResolve(segments: [TranscriptSegment]) async -> [String: String] {
        lock.lock()
        let micCopy = micSamples
        let sysCopy = sysSamples
        let energyCopy = energyLog
        lock.unlock()

        guard models != nil else {
            log.warning("Sortformer models not loaded — skipping diarization")
            return [:]
        }

        guard !micCopy.isEmpty else {
            log.warning("No audio accumulated — skipping diarization")
            return [:]
        }

        // Cap audio at 10 minutes for Sortformer — it's designed for meeting segments,
        // not long recordings. Sample evenly from the full audio to capture speaker variety.
        let maxSamples = Int(StereoMixer.sampleRate * 600) // 10 min at 16 kHz
        let micInput = Self.downsample(micCopy, toMaxSamples: maxSamples)
        let sysInput = Self.downsample(sysCopy, toMaxSamples: maxSamples)

        log.info("Running diarization on \(micInput.count) mic + \(sysInput.count) sys samples (capped from \(micCopy.count))")

        guard let loadedModels = models else {
            log.warning("[Diarizer] Models not loaded — skipping")
            return [:]
        }

        // Create two separate diarizer instances for mic and system channels
        let micDiarizer = SortformerDiarizer(config: .balancedV2_1)
        let sysDiarizer = SortformerDiarizer(config: .balancedV2_1)

        micDiarizer.initialize(models: loadedModels)
        sysDiarizer.initialize(models: loadedModels)

        // Run diarization on both channels (processComplete is CPU-intensive — run off cooperative pool)
        let micTimeline: DiarizerTimeline
        let sysTimeline: DiarizerTimeline
        do {
            micTimeline = try await Task.detached(priority: .userInitiated) {
                try micDiarizer.processComplete(micInput, sourceSampleRate: StereoMixer.sampleRate)
            }.value
            log.info("Mic diarization complete — \(micTimeline.speakers.count) speakers")
        } catch {
            log.error("Mic diarization failed: \(error.localizedDescription)")
            return [:]
        }

        do {
            sysTimeline = try await Task.detached(priority: .userInitiated) {
                try sysDiarizer.processComplete(sysInput, sourceSampleRate: StereoMixer.sampleRate)
            }.value
            log.info("System diarization complete — \(sysTimeline.speakers.count) speakers")
        } catch {
            log.error("System diarization failed: \(error.localizedDescription)")
            return [:]
        }

        // Resolve each segment
        var result: [String: String] = [:]
        for segment in segments {
            let label = resolve(
                segment: segment,
                micTimeline: micTimeline,
                sysTimeline: sysTimeline,
                energyLog: energyCopy
            )
            result[segment.id.uuidString] = label
        }

        log.info("Resolved \(result.count) segments to speaker labels")
        return result
    }

    // MARK: - Resolution

    /// Resolves a transcript segment to a speaker label using echo suppression.
    ///
    /// If a mic-channel segment falls during a system-audio-dominant period
    /// (system energy > 1.2x mic energy), it is attributed to a remote speaker
    /// instead, since the mic is likely picking up echo from the system audio.
    private func resolve(
        segment: TranscriptSegment,
        micTimeline: DiarizerTimeline,
        sysTimeline: DiarizerTimeline,
        energyLog: [(startSec: Double, endSec: Double, micEnergy: Float, sysEnergy: Float)]
    ) -> String {
        let midpoint = (segment.startSeconds + segment.endSeconds) / 2.0

        // Check energy ratio at the midpoint for echo suppression
        let echoThreshold: Float = 1.2
        let isSystemDominant = energyEntry(atSec: midpoint, in: energyLog).map { entry in
            entry.sysEnergy > entry.micEnergy * echoThreshold
        } ?? false

        switch segment.channel {
        case .microphone:
            if isSystemDominant {
                // Mic picked up echo — attribute to remote speaker
                return speakerLabel(in: sysTimeline, atSec: midpoint, prefix: "Remote")
            } else {
                return speakerLabel(in: micTimeline, atSec: midpoint, prefix: "Room")
            }
        case .system:
            return speakerLabel(in: sysTimeline, atSec: midpoint, prefix: "Remote")
        case .unknown:
            // Best-effort: treat unknown channel as mic
            return speakerLabel(in: micTimeline, atSec: midpoint, prefix: "Room")
        }
    }

    /// Finds which speaker is active at the given time in the timeline.
    private func speakerLabel(in timeline: DiarizerTimeline, atSec: Double, prefix: String) -> String {
        let t = Float(atSec)

        // Search all speakers for a segment containing this time
        for (_, speaker) in timeline.speakers {
            let allSegments = speaker.finalizedSegments + speaker.tentativeSegments
            for seg in allSegments {
                if seg.startTime <= t && t <= seg.endTime {
                    return "\(prefix) \(speaker.index + 1)"
                }
            }
        }

        // Fallback: no speaker found at this time
        return "\(prefix) 1"
    }

    /// Finds the energy log entry covering the given time.
    private func energyEntry(
        atSec sec: Double,
        in log: [(startSec: Double, endSec: Double, micEnergy: Float, sysEnergy: Float)]
    ) -> (startSec: Double, endSec: Double, micEnergy: Float, sysEnergy: Float)? {
        log.first { entry in
            entry.startSec <= sec && sec < entry.endSec
        }
    }

    // MARK: - Utilities

    /// Computes root-mean-square energy of a sample buffer.
    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }

    /// Evenly sample `input` down to at most `maxSamples` by taking uniformly
    /// spaced windows. If `input.count <= maxSamples`, returns `input` unchanged.
    private static func downsample(_ input: [Float], toMaxSamples maxSamples: Int) -> [Float] {
        guard input.count > maxSamples else { return input }
        let stride = input.count / maxSamples
        var output = [Float]()
        output.reserveCapacity(maxSamples)
        var i = 0
        while i < input.count && output.count < maxSamples {
            output.append(input[i])
            i += stride
        }
        return output
    }
}
#endif
