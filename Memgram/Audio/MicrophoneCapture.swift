import AVFoundation
import Combine

final class MicrophoneCapture {

    private let engine = AVAudioEngine()
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private(set) var isRunning = false

    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        subject.eraseToAnyPublisher()
    }

    func start() throws {
        let inputNode = engine.inputNode

        // Echo cancellation (OPT-IN, default off): with speakers, the mic picks up
        // the system audio it is playing — the bleed makes mic/system energies
        // nearly equal, defeating selectDominantChannel's threshold and smearing
        // the averaged signal with a room-delayed echo. Apple's voice processing
        // subtracts the rendered output from the mic signal at the source.
        // Default OFF because the voice-processing unit always ducks "other
        // audio" somewhat — even with duckingLevel .min — and the "other audio"
        // is the meeting the user is listening to (audibly quieter playback).
        // Fail soft: worst case we record exactly as before.
        if UserDefaults.standard.bool(forKey: "echoCancellationEnabled") {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    // Never duck other audio — the "other audio" is the meeting
                    // the user is listening to (and our system-audio tap source).
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        .init(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                // Some devices/route combinations reject voice processing.
                try? inputNode.setVoiceProcessingEnabled(false)
            }
        }

        // Read the format AFTER configuring voice processing — enabling it
        // changes the input node's output format.
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self,
                  let mono = Self.extractMono(from: buffer),
                  let resampled = AudioConverter.resampleToMono16k(mono) else { return }
            self.subject.send(resampled)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Copies channel 0 of any multi-channel buffer into a mono buffer at the native sample rate.
    /// Bypasses AVAudioConverter's downmix matrix which zeroes out for unusual channel counts.
    private static func extractMono(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)
        dst.initialize(from: src, count: frames)
        return mono
    }
}
