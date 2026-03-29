import Foundation

enum LLMBackend: String, CaseIterable, Identifiable {
    case qwen    = "qwen"     // Local Qwen via MLX
    case custom  = "custom"
    case claude  = "claude"
    case openai  = "openai"
    case gemini  = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen:   return "Default (Qwen 3.5 9B)"
        case .custom: return "Custom Server"
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var badge: String {
        switch self {
        case .qwen: return "Free"
        case .custom: return "Self-hosted"
        case .claude, .openai, .gemini: return "API key"
        }
    }

    /// Returns true if this backend has enough configuration to attempt a request.
    var isConfigured: Bool {
        switch self {
        case .qwen:
            return true  // always available — Qwen auto-downloads
        case .custom:
            return true  // always show — same logic as Ollama; connection errors surface separately
        case .claude:
            return !(KeychainHelper.load(key: "claudeAPIKey") ?? "").isEmpty
        case .openai:
            return !(KeychainHelper.load(key: "openaiAPIKey") ?? "").isEmpty
        case .gemini:
            return !(KeychainHelper.load(key: "geminiAPIKey") ?? "").isEmpty
        }
    }
}

protocol LLMProvider {
    var name: String { get }
    func complete(system: String, user: String) async throws -> String
    func embed(text: String) async throws -> [Float]
}
