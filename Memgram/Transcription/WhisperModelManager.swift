import Foundation
import Combine

// Internal model cases kept for WhisperKit name mapping — not exposed in UI
enum WhisperModel: String, CaseIterable, Identifiable {
    case smallEn      = "openai_whisper-small.en"
    case small        = "openai_whisper-small"
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3Full  = "openai_whisper-large-v3_turbo_954MB"

    var id: String { rawValue }
    var whisperKitName: String { rawValue }

    var shortName: String {
        switch self {
        case .smallEn:      return "Small EN"
        case .small:        return "Small"
        case .largeV3Turbo: return "Large v3 Turbo Q"
        case .largeV3Full:  return "Large v3 Turbo"
        }
    }

    var sizeMB: Int {
        switch self {
        case .smallEn:      return 244
        case .small:        return 244
        case .largeV3Turbo: return 632
        case .largeV3Full:  return 954
        }
    }
}

@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    /// True while WhisperKit is downloading or loading the model for the first time.
    @Published var isWhisperDownloading: Bool = false

    /// True = multilingual; False = English-only (faster, higher accuracy for English)
    @Published var preferMultilingual: Bool {
        didSet { UserDefaults.standard.set(preferMultilingual, forKey: "preferMultilingual") }
    }

    /// Model chosen automatically based on language preference and available RAM.
    var selectedModel: WhisperModel { autoSelectedModel }

    var isModelReady: Bool { true }

    /// How much physical RAM this machine has (GiB).
    static var ramGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Automatically pick the best model the hardware can comfortably run.
    ///
    /// Thresholds (Apple Silicon Mac line-up: 8 / 16 / 24 / 32 GB+):
    ///  < 8 GB  → Small (244 MB) — unlikely on modern Apple Silicon but safe fallback
    ///  8 GB    → Large v3 Turbo Q (632 MB) — fits easily, excellent quality
    ///  ≥ 16 GB → Large v3 Turbo full (954 MB) — full precision, best quality
    var autoSelectedModel: WhisperModel {
        let ram = Self.ramGB
        if ram >= 16 {
            return .largeV3Full
        } else if ram >= 8 {
            return .largeV3Turbo
        } else {
            return preferMultilingual ? .small : .smallEn
        }
    }

    private init() {
        // Default to International — covers more use cases out of the box
        if UserDefaults.standard.object(forKey: "preferMultilingual") == nil {
            preferMultilingual = true  // first launch default
        } else {
            preferMultilingual = UserDefaults.standard.bool(forKey: "preferMultilingual")
        }
    }
}
