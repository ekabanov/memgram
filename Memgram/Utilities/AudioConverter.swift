import AVFoundation

/// Resampling and format conversion utilities.
enum AudioConverter {

    /// Resamples any AVAudioPCMBuffer to 16 kHz mono Float32.
    /// Returns nil only if the input format is completely unusable.
    static func resampleToMono16k(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // If already in target format, return as-is
        if input.format.sampleRate == 16000 &&
           input.format.channelCount == 1 &&
           input.format.commonFormat == .pcmFormatFloat32 {
            return input
        }

        guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else {
            return nil
        }

        let inputFrames = Double(input.frameLength)
        let ratio = 16000.0 / input.format.sampleRate
        let outputFrames = AVAudioFrameCount(ceil(inputFrames * ratio)) + 1

        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else {
            return nil
        }

        var inputConsumed = false
        let status = converter.convert(to: output, error: nil) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return input
        }

        guard status != .error else { return nil }
        return output
    }

    /// Mix a stereo (interleaved or non-interleaved) buffer down to mono Float32.
    static func mixdownToMono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.format.channelCount >= 1 else { return nil }
        if input.format.channelCount == 1 { return input }

        let monoFormat = AVAudioFormat(
            commonFormat: input.format.commonFormat,
            sampleRate: input.format.sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameCapacity) else { return nil }
        output.frameLength = input.frameLength

        guard let outData = output.floatChannelData?[0],
              let inData = input.floatChannelData else { return nil }

        let frames = Int(input.frameLength)
        let channelCount = Int(input.format.channelCount)
        let scale = 1.0 / Float(channelCount)

        for i in 0..<frames {
            var sum: Float = 0
            for ch in 0..<channelCount {
                sum += inData[ch][i]
            }
            outData[i] = sum * scale
        }
        return output
    }

    /// Build a stereo interleaved buffer by placing left in channel 0 and right in channel 1.
    /// Both inputs must already be mono 16kHz Float32. Pads the shorter one with silence.
    static func mergeToStereo(left: AVAudioPCMBuffer, right: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let stereoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 2,
            interleaved: false
        )!

        let frameCount = max(left.frameLength, right.frameLength)
        guard let output = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frameCount) else { return nil }
        output.frameLength = frameCount

        guard let outChannels = output.floatChannelData else { return nil }

        let frames = Int(frameCount)

        if let leftData = left.floatChannelData?[0] {
            for i in 0..<min(frames, Int(left.frameLength)) { outChannels[0][i] = leftData[i] }
        }
        if let rightData = right.floatChannelData?[0] {
            for i in 0..<min(frames, Int(right.frameLength)) { outChannels[1][i] = rightData[i] }
        }

        return output
    }
}
