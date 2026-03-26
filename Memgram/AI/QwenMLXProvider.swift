// Memgram/AI/QwenMLXProvider.swift
import Foundation

#if canImport(MLXLLM)
import MLXLLM
import Hub

@available(macOS 14.0, *)
@MainActor
final class QwenMLXProvider: ObservableObject, LLMProvider {
    static let shared = QwenMLXProvider()
    static let modelID = "mlx-community/Qwen3.5-9B-MLX-4bit"

    let name = "Qwen 3.5 9B (local)"

    @Published var downloadProgress: Double = 0
    @Published var isLoaded = false
    @Published var loadError: String?

    private var modelContainer: ModelContainer?

    private init() {}

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        let container = try await getOrLoadContainer()

        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user]
        ]

        let promptTokens = try await container.perform { _, tokenizer in
            try tokenizer.applyChatTemplate(messages: messages)
        }

        let params = GenerateParameters(temperature: 0.6)

        let result: GenerateResult = await container.perform { model, tokenizer in
            generate(
                promptTokens: promptTokens,
                parameters: params,
                model: model,
                tokenizer: tokenizer
            ) { _ in .more }
        }

        return result.output
    }

    func embed(text: String) async throws -> [Float] {
        // MLXLLM is a text-generation library; fall back to Ollama for embeddings
        return try await OllamaProvider().embed(text: text)
    }

    // MARK: - Loading

    func loadModel() async throws {
        guard modelContainer == nil else { return }

        loadError = nil
        downloadProgress = 0

        let configuration = ModelConfiguration(id: Self.modelID)

        let hub = HubApi()

        let container = try await loadModelContainer(
            hub: hub,
            configuration: configuration
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        self.modelContainer = container
        self.downloadProgress = 1.0
        self.isLoaded = true
    }

    func preload() {
        Task {
            do {
                try await loadModel()
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Private helpers

    private func getOrLoadContainer() async throws -> ModelContainer {
        if let container = modelContainer {
            return container
        }
        try await loadModel()
        guard let container = modelContainer else {
            throw QwenMLXError.modelNotLoaded
        }
        return container
    }
}

private enum QwenMLXError: Error, LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Qwen model failed to load."
        }
    }
}

#endif
