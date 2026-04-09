import Foundation
import Combine

@MainActor
final class TranscriptionBackendManager: ObservableObject {
    static let shared = TranscriptionBackendManager()

    private let backendKey = "transcriptionBackend"

    /// The backend the user has selected (persisted in UserDefaults).
    @Published var selectedBackend: TranscriptionBackend {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: backendKey) }
    }

    /// True while Parakeet model is downloading or loading.
    @Published var isLoading: Bool = false

    /// True once Parakeet model is fully ready.
    @Published var isParakeetReady: Bool = false

    private init() {
        let saved = UserDefaults.standard.string(forKey: backendKey) ?? ""
        if let explicit = TranscriptionBackend(rawValue: saved) {
            selectedBackend = explicit
        } else {
            // Default: Whisper on machines with enough RAM, Parakeet on low-RAM devices
            selectedBackend = WhisperModelManager.ramGB >= 8 ? .whisper : .parakeet
        }
    }
}
