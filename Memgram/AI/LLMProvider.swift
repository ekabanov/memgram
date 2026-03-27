import Foundation

enum LLMBackendCategory: String, CaseIterable {
    case freeLocal  = "Free Local"
    case selfHosted = "Self-Hosted"
    case cloud      = "Cloud"
}

enum LLMBackend: String, CaseIterable, Identifiable {
    case qwen    = "qwen"     // Local Qwen via MLX
    case ollama  = "ollama"
    case custom  = "custom"
    case claude  = "claude"
    case openai  = "openai"
    case gemini  = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen:   return "Qwen 3.5 9B (Local)"
        case .ollama: return "Ollama"
        case .custom: return "Custom Server"
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var category: LLMBackendCategory {
        switch self {
        case .qwen, .ollama:            return .freeLocal
        case .custom:                   return .selfHosted
        case .claude, .openai, .gemini: return .cloud
        }
    }

    var badge: String {
        switch self {
        case .qwen, .ollama: return "Free"
        case .custom: return "Self-hosted"
        case .claude, .openai, .gemini: return "API key"
        }
    }
}

protocol LLMProvider {
    var name: String { get }
    func complete(system: String, user: String) async throws -> String
    func embed(text: String) async throws -> [Float]
}
