import AVFoundation
import ScreenCaptureKit
import Combine

final class ScreenCaptureKitCapture: NSObject, SystemAudioCaptureProvider, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()

    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        subject.eraseToAnyPublisher()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Minimum 1fps video surface — required to avoid "stream output NOT found" console spam,
        // even though we discard all screen frames immediately
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        // MUST register BOTH outputs even though screen frames are discarded
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await newStream.startCapture()
        self.stream = newStream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }  // Discard screen frames completely

        guard let pcmBuf = buffer.toAVAudioPCMBuffer() else { return }
        if let resampled = AudioConverter.resampleToMono16k(pcmBuf) {
            subject.send(resampled)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // SCKit is known to drop randomly on macOS 14.x — auto-restart
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await self.start()
        }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toAVAudioPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee,
              let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else { return nil }
        pcmBuf.frameLength = frameCount

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount),
            into: pcmBuf.mutableAudioBufferList
        ) == noErr else { return nil }

        return pcmBuf
    }
}
