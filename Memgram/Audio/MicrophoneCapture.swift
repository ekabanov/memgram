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
