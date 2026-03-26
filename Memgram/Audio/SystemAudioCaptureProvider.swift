import AVFoundation
import Combine

protocol SystemAudioCaptureProvider: AnyObject {
    func start() async throws
    func stop() async
    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> { get }
}

func makeSystemAudioCapture() -> SystemAudioCaptureProvider {
    if #available(macOS 14.4, *) {
        return CoreAudioTapCapture()
    } else {
        return ScreenCaptureKitCapture()
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case formatUnavailable
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):   return "CoreAudio tap creation failed: \(s)"
        case .aggregateDeviceFailed(let s): return "Aggregate device creation failed: \(s)"
        case .ioProcFailed(let s):        return "IOProc creation failed: \(s)"
        case .formatUnavailable:          return "Could not read audio format from tap"
        case .noDisplay:                  return "No display found for ScreenCaptureKit"
        }
    }
}
