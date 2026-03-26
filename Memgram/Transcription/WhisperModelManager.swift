import Foundation
import Combine

enum WhisperModel: String, CaseIterable, Identifiable {
    // English-only
    case tinyEn   = "tiny.en"
    case baseEn   = "base.en"
    case smallEn  = "small.en"
    case mediumEn = "medium.en"
    // Multilingual
    case tiny   = "tiny"
    case base   = "base"
    case small  = "small"
    case medium = "medium"
    // Large (multilingual)
    case largeV2       = "large-v2"
    case largeV3       = "large-v3"
    case largeV3Turbo  = "large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyEn:       return "Tiny EN (75 MB) — English only, fastest"
        case .baseEn:       return "Base EN (142 MB) — English only"
        case .smallEn:      return "Small EN (466 MB) — English only"
        case .mediumEn:     return "Medium EN (1.5 GB) — English only, best EN accuracy"
        case .tiny:         return "Tiny (75 MB) — multilingual"
        case .base:         return "Base (142 MB) — multilingual"
        case .small:        return "Small (466 MB) — multilingual"
        case .medium:       return "Medium (1.5 GB) — multilingual"
        case .largeV2:      return "Large v2 (2.9 GB) — multilingual, high accuracy"
        case .largeV3:      return "Large v3 (3.1 GB) — multilingual, best accuracy"
        case .largeV3Turbo: return "Large v3 Turbo (1.6 GB) — multilingual, fast + accurate"
        }
    }

    /// Model variant name used by WhisperKit
    var whisperKitName: String { rawValue }

    var isEnglishOnly: Bool {
        switch self {
        case .tinyEn, .baseEn, .smallEn, .mediumEn: return true
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

    /// WhisperKit downloads and caches models automatically — always ready to attempt.
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
