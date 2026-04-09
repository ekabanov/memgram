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
            // Whisper Large v3 Turbo needs headroom — fall back to Parakeet on 8GB machines
            selectedBackend = WhisperModelManager.ramGB >= 12 ? .whisper : .parakeet
        }
    }
}
