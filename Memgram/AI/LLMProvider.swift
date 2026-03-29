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
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error>
    func embed(text: String) async throws -> [Float]
}

extension LLMProvider {
    /// Default: wraps complete() — yields the full response as a single chunk.
    /// Providers that support real streaming override this.
    ///
    /// Uses Task.detached (not bare Task{}) so the call to complete() is always
    /// explicitly off any actor context. A bare Task{} can inherit @MainActor
    /// isolation under SWIFT_STRICT_CONCURRENCY:minimal, which deadlocks MLX's
    /// internal AsyncMutex when called on QwenLocalProvider.
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached {
                do {
                    let result = try await self.complete(system: system, user: user)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
