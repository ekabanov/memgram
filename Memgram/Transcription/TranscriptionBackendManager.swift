import Foundation

// Temporary stub — will be replaced by full TranscriptionBackendManager in Task 5
@MainActor
final class TranscriptionBackendManager: ObservableObject {
    static let shared = TranscriptionBackendManager()
    @Published var isLoading = false
    @Published var isReady = false
    private init() {}
}
