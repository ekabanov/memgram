import Foundation
import Combine

enum WhisperModel: String, CaseIterable, Identifiable {
    // English-only (small / fast)
    case tinyEn  = "openai_whisper-tiny.en"
    case baseEn  = "openai_whisper-base.en"
    case smallEn = "openai_whisper-small.en"
    // Multilingual (small / fast)
    case tiny    = "openai_whisper-tiny"
    case base    = "openai_whisper-base"
    case small   = "openai_whisper-small"
    // Large (quantized — good quality, reasonable size)
    case largeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"   // recommended default
    case largeV3      = "openai_whisper-large-v3-v20240930_626MB"
    case largeV3Full  = "openai_whisper-large-v3_turbo_954MB"
    case largeV2      = "openai_whisper-large-v2_949MB"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyEn:       return "Tiny EN (39 MB) — English only, fastest"
        case .baseEn:       return "Base EN (74 MB) — English only, fast"
        case .smallEn:      return "Small EN (244 MB) — English only, good"
        case .tiny:         return "Tiny (39 MB) — multilingual"
        case .base:         return "Base (74 MB) — multilingual"
        case .small:        return "Small (244 MB) — multilingual"
        case .largeV3Turbo: return "Large v3 Turbo Q (632 MB) — multilingual, recommended ✦"
        case .largeV3:      return "Large v3 Q (626 MB) — multilingual, high accuracy"
        case .largeV3Full:  return "Large v3 Turbo (954 MB) — multilingual, full precision"
        case .largeV2:      return "Large v2 (949 MB) — multilingual"
        }
    }

    /// Model variant name passed to WhisperKit
    var whisperKitName: String { rawValue }

    /// Short label for buttons and compact UI
    var shortName: String {
        switch self {
        case .tinyEn:       return "Tiny EN"
        case .baseEn:       return "Base EN"
        case .smallEn:      return "Small EN"
        case .tiny:         return "Tiny"
        case .base:         return "Base"
        case .small:        return "Small"
        case .largeV3Turbo: return "Large v3 Turbo Q"
        case .largeV3:      return "Large v3 Q"
        case .largeV3Full:  return "Large v3 Turbo"
        case .largeV2:      return "Large v2"
        }
    }

    var isEnglishOnly: Bool {
        switch self {
        case .tinyEn, .baseEn, .smallEn: return true
        default: return false
        }
    }
}

@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()

    @Published var selectedModel: WhisperModel = .largeV3Turbo {
        didSet {
            UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedWhisperModel")
            print("[WhisperModelManager] Model selected: \(selectedModel.displayName)")
        }
    }

    var isModelReady: Bool { true }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "selectedWhisperModel"),
           let model = WhisperModel(rawValue: saved) {
            selectedModel = model
        }
    }

    func selectModel(_ model: WhisperModel) {
        selectedModel = model
    }
}
