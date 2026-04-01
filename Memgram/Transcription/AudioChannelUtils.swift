import AVFoundation

/// Extract audio from the dominant channel of a stereo 16 kHz buffer.
///
/// - If mic (L) energy exceeds system (R) energy by `threshold`, return mic only.
/// - If system (R) energy exceeds mic (L) energy by `threshold`, return system only.
/// - Otherwise return the average of both channels.
///
/// This prevents echo reinforcement: when a remote speaker's voice leaks through
/// room speakers into the mic, selecting only the system channel for transcription
/// avoids the doubled/louder signal that causes duplicate transcript segments.
func selectDominantChannel(
    _ buffer: AVAudioPCMBuffer,
    leftEnergy: Float,
    rightEnergy: Float,
    threshold: Float = 1.2
) -> [Float]? {
    guard let channels = buffer.floatChannelData else { return nil }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard channelCount >= 1, frames > 0 else { return nil }

    // Single-channel buffer — just return it
    if channelCount == 1 {
        return Array(UnsafeBufferPointer(start: channels[0], count: frames))
    }

    // Two-channel: pick dominant or average
    let left  = Array(UnsafeBufferPointer(start: channels[0], count: frames))
    let right = Array(UnsafeBufferPointer(start: channels[1], count: frames))

    if leftEnergy  > rightEnergy * threshold { return left }
    if rightEnergy > leftEnergy  * threshold { return right }

    // Neither clearly dominant — average
    var mono = [Float](repeating: 0, count: frames)
    for i in 0..<frames { mono[i] = (left[i] + right[i]) * 0.5 }
    return mono
}
