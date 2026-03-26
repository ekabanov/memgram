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

    private init() {
        let saved = UserDefaults.standard.string(forKey: "llmBackend") ?? ""
        selectedBackend = LLMBackend(rawValue: saved) ?? .ollama
        ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2"
    }

    var currentProvider: any LLMProvider {
        switch selectedBackend {
        case .ollama:
            return OllamaProvider(model: ollamaModel)
        case .claude:
            return ClaudeProvider(apiKey: KeychainHelper.load(key: "claudeAPIKey") ?? "")
        case .openai:
            return OpenAIProvider(apiKey: KeychainHelper.load(key: "openaiAPIKey") ?? "")
        }
    }

    func fetchOllamaModels() async -> [String] {
        return await OllamaProvider(model: ollamaModel).listModels()
    }
}
