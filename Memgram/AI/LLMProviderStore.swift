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
        let p = providerFor(selectedBackend)
        print("[LLMProviderStore] currentProvider → \(p.name)")
        return p
    }

    /// Returns the provider for a specific backend without changing selectedBackend.
    func providerFor(_ backend: LLMBackend) -> any LLMProvider {
        switch backend {
        case .qwen:
            #if canImport(MLXLLM)
            if #available(macOS 14, *) { return QwenLocalProvider.shared }
            else { return OllamaProvider(model: "qwen3:8b") }
            #else
            return OllamaProvider(model: "qwen3:8b")
            #endif
        case .ollama:
            return OllamaProvider(model: ollamaModel)
        case .custom:
            return CustomServerProvider(
                baseURL:   customServerURL,
                apiKey:    KeychainHelper.load(key: "customServerKey") ?? "",
                modelName: customServerModel
            )
        case .claude:
            return ClaudeProvider(apiKey: KeychainHelper.load(key: "claudeAPIKey") ?? "")
        case .openai:
            return OpenAIProvider(apiKey: KeychainHelper.load(key: "openaiAPIKey") ?? "")
        case .gemini:
            return GeminiProvider(apiKey: KeychainHelper.load(key: "geminiAPIKey") ?? "")
        }
    }

    func fetchOllamaModels() async -> [String] {
        await OllamaProvider(model: ollamaModel).listModels()
    }
}
