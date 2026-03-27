import Foundation
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
    private init() {}

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        if modelContainer == nil {
            try await loadModel()
        }
        guard let container = modelContainer else {
            throw QwenError.modelNotLoaded
        }
        let session = ChatSession(container, instructions: system)
        return try await session.respond(to: user)
    }

    func embed(text: String) async throws -> [Float] {
        // MLXLLM is text-generation only; delegate to OllamaProvider for embeddings
        try await OllamaProvider().embed(text: text)
    }

    // MARK: - Model loading

    func loadModel() async throws {
        guard !isLoaded else { return }

        let config = ModelConfiguration(
            id: Self.modelID,
            defaultPrompt: "Hello"
        )

        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: config
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        modelContainer = container
        isLoaded = true
        downloadProgress = 1.0
    }

    func preload() {
        Task {
            do { try await loadModel() }
            catch {
                loadError = error.localizedDescription
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
