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

    /// True while Sortformer diarization models are downloading or compiling.
    @Published var isDiarizerLoading: Bool = false

    /// True once Sortformer models are compiled and ready.
    @Published var isDiarizerReady: Bool = false

    private init() {
        let saved = UserDefaults.standard.string(forKey: backendKey) ?? ""
        selectedBackend = TranscriptionBackend(rawValue: saved) ?? .parakeet
    }
}
