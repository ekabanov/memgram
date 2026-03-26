import Foundation
import Combine

@MainActor
final class LLMProviderStore: ObservableObject {
    static let shared = LLMProviderStore()

    @Published var selectedBackend: LLMBackend {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: "llmBackend") }
    }
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel") }
    }
    @Published var mlxPort: Int {
        didSet { UserDefaults.standard.set(mlxPort, forKey: "mlxPort") }
    }
    @Published var mlxModel: String {
        didSet { UserDefaults.standard.set(mlxModel, forKey: "mlxModel") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "llmBackend") ?? ""
        selectedBackend = LLMBackend(rawValue: saved) ?? .ollama
        ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2"
        mlxPort  = UserDefaults.standard.integer(forKey: "mlxPort").nonZero ?? 8080
        mlxModel = UserDefaults.standard.string(forKey: "mlxModel") ?? "mlx-community/Qwen3-8B-4bit"
    }

    var currentProvider: any LLMProvider {
        switch selectedBackend {
        case .ollama:
            return OllamaProvider(model: ollamaModel)
        case .claude:
            return ClaudeProvider(apiKey: KeychainHelper.load(key: "claudeAPIKey") ?? "")
        case .openai:
            return OpenAIProvider(apiKey: KeychainHelper.load(key: "openaiAPIKey") ?? "")
        case .mlx:
            return MLXProvider(port: mlxPort, modelName: mlxModel)
        }
    }

    func fetchOllamaModels() async -> [String] {
        return await OllamaProvider(model: ollamaModel).listModels()
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
