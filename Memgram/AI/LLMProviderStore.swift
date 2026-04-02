import Foundation
import Combine
import OSLog

private let log = Logger.make("AI")

@MainActor
final class LLMProviderStore: ObservableObject {
    static let shared = LLMProviderStore()

    @Published var selectedBackend: LLMBackend {
        didSet {
            UserDefaults.standard.set(selectedBackend.rawValue, forKey: "llmBackend")
            // Cancel any in-progress Qwen download when user switches away
            if oldValue == .qwen && selectedBackend != .qwen {
                #if canImport(MLXLLM)
                if #available(macOS 14, *) {
                    QwenLocalProvider.shared.cancelDownload()
                }
                #endif
            }
        }
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
        customServerURL   = UserDefaults.standard.string(forKey: "customServerURL") ?? "http://localhost:1234"
        customServerModel = UserDefaults.standard.string(forKey: "customServerModel") ?? "local-model"
        log.info("Loaded — backend: \(self.selectedBackend.displayName) (raw saved: \(saved))")
    }

    var currentProvider: any LLMProvider {
        let p = providerFor(selectedBackend)
        log.debug("currentProvider → \(p.name)")
        return p
    }

    /// Returns the provider for a specific backend without changing selectedBackend.
    func providerFor(_ backend: LLMBackend) -> any LLMProvider {
        switch backend {
        case .qwen:
            #if canImport(MLXLLM)
            if #available(macOS 14, *) { return QwenLocalProvider.shared }
            else {
                return CustomServerProvider(
                    baseURL:   customServerURL,
                    apiKey:    KeychainHelper.load(key: "customServerKey") ?? "",
                    modelName: customServerModel
                )
            }
            #else
            return CustomServerProvider(
                baseURL:   customServerURL,
                apiKey:    KeychainHelper.load(key: "customServerKey") ?? "",
                modelName: customServerModel
            )
            #endif
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

}
