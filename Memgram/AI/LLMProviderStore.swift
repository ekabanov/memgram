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
    @Published var customServerURL: String {
        didSet { UserDefaults.standard.set(customServerURL, forKey: "customServerURL") }
    }
    @Published var customServerModel: String {
        didSet { UserDefaults.standard.set(customServerModel, forKey: "customServerModel") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "llmBackend") ?? ""
        selectedBackend   = LLMBackend(rawValue: saved) ?? .qwen
        ollamaModel       = UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2"
        customServerURL   = UserDefaults.standard.string(forKey: "customServerURL") ?? "http://localhost:1234"
        customServerModel = UserDefaults.standard.string(forKey: "customServerModel") ?? "local-model"
        print("[LLMProviderStore] Loaded — backend: \(selectedBackend.displayName) (raw saved: '\(saved)')")
    }

    var currentProvider: any LLMProvider {
        let provider: any LLMProvider
        switch selectedBackend {
        case .qwen:
            #if canImport(MLXLLM)
            if #available(macOS 14, *) { provider = QwenLocalProvider.shared }
            else { provider = OllamaProvider(model: "qwen3:8b") }
            #else
            provider = OllamaProvider(model: "qwen3:8b")
            #endif
        case .ollama:
            provider = OllamaProvider(model: ollamaModel)
        case .custom:
            provider = CustomServerProvider(
                baseURL:   customServerURL,
                apiKey:    KeychainHelper.load(key: "customServerKey") ?? "",
                modelName: customServerModel
            )
        case .claude:
            provider = ClaudeProvider(apiKey: KeychainHelper.load(key: "claudeAPIKey") ?? "")
        case .openai:
            provider = OpenAIProvider(apiKey: KeychainHelper.load(key: "openaiAPIKey") ?? "")
        case .gemini:
            provider = GeminiProvider(apiKey: KeychainHelper.load(key: "geminiAPIKey") ?? "")
        }
        print("[LLMProviderStore] currentProvider → \(provider.name)")
        return provider
    }

    func fetchOllamaModels() async -> [String] {
        await OllamaProvider(model: ollamaModel).listModels()
    }
}
