import Foundation
import Combine

// Internal model cases kept for WhisperKit name mapping — not exposed in UI
enum WhisperModel: String, CaseIterable, Identifiable {
    case smallEn      = "openai_whisper-small.en"
    case small        = "openai_whisper-small"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3Full  = "openai_whisper-large-v3"

    var id: String { rawValue }
    var whisperKitName: String { rawValue }

    var shortName: String {
        switch self {
        case .smallEn:      return "Small EN"
        case .small:        return "Small"
        case .largeV3Turbo: return "Large v3 Turbo Q"
        case .largeV3Full:  return "Large v3"
        }
    }

    var sizeMB: Int {
        switch self {
        case .smallEn:      return 244
        case .small:        return 244
        case .largeV3Turbo: return 632
        case .largeV3Full:  return 1550
        }
    }
}

@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    /// True while WhisperKit is downloading, loading, or compiling the model.
    @Published var isWhisperDownloading: Bool = false

    /// True once the model is fully loaded and CoreML warm-up is complete.
    @Published var isWhisperReady: Bool = false

    /// Model chosen automatically based on available RAM. Always multilingual.
    var selectedModel: WhisperModel { autoSelectedModel }

    /// How much physical RAM this machine has (GiB).
    static var ramGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Automatically pick the best model the hardware can comfortably run.
    ///
    /// Thresholds (Apple Silicon Mac line-up: 8 / 16 / 24 / 32 GB+):
    ///  < 8 GB  → Small multilingual (244 MB) — safe fallback
    ///  8 GB    → Large v3 Turbo Q (632 MB) — fits easily, excellent quality
    ///  ≥ 16 GB → Large v3 (~1.5 GB) — full precision, best quality
    var autoSelectedModel: WhisperModel {
        let ram = Self.ramGB
        if ram >= 16 { return .largeV3Full }
        if ram >= 8  { return .largeV3Turbo }
        return .small  // multilingual small — smallEn retired
    }

    private init() {}
}
