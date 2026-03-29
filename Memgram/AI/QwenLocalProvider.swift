import Foundation
import OSLog
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon

@available(macOS 14.0, *)
@MainActor
final class QwenLocalProvider: ObservableObject, LLMProvider {
    static let shared = QwenLocalProvider()
    static let modelID = "mlx-community/Qwen3.5-9B-MLX-4bit"

    let name = "Qwen 3.5 9B (local)"

    @Published var downloadProgress: Double = 0
    @Published var isLoaded = false
    @Published var loadError: String?

    private var modelContainer: ModelContainer?
    private let log = Logger.make("AI")
    private init() {}

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        log.debug("complete() called — model loaded: \(self.isLoaded)")
        if modelContainer == nil {
            log.info("Model not loaded yet, loading")
            try await loadModel()
        }
        guard let container = modelContainer else {
            log.error("Model container is nil after load attempt")
            throw QwenError.modelNotLoaded
        }
        log.debug("Creating ChatSession")
        let session = ChatSession(container, instructions: system)
        let start = Date()
        log.debug("Generating response")
        let response = try await session.respond(to: user)
        let elapsed = Date().timeIntervalSince(start)
        log.info("Response generated in \(String(format: "%.1f", elapsed))s — \(response.count) chars")
        return response
    }

    func embed(text: String) async throws -> [Float] {
        try await OllamaProvider().embed(text: text)
    }

    // MARK: - Model loading

    func loadModel() async throws {
        guard !isLoaded else {
            log.debug("Model already loaded, skipping")
            return
        }

        log.info("Loading model: \(Self.modelID, privacy: .public)")
        loadError = nil
        downloadProgress = 0

        let config = ModelConfiguration(
            id: Self.modelID,
            defaultPrompt: "Hello"
        )

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { [weak self] progress in
                let frac = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    self?.downloadProgress = frac
                }
                if Int(frac * 100) % 10 == 0 {
                    self?.log.debug("Download progress: \(Int(frac * 100))%")
                }
            }

            modelContainer = container
            isLoaded = true
            downloadProgress = 1.0
            log.info("Model loaded successfully")
        } catch {
            log.error("Model load failed: \(error)")
            loadError = error.localizedDescription
            throw error
        }
    }

    func preload() {
        log.info("preload() called")
        Task {
            do { try await loadModel() }
            catch {
                self.log.error("preload() failed: \(error)")
                self.loadError = error.localizedDescription
            }
        }
    }
}

@available(macOS 14.0, *)
private enum QwenError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Qwen model is not loaded"
        }
    }
}
#endif
