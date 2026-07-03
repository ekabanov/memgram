import Foundation

enum LLMBackend: String, CaseIterable, Identifiable {
    case qwen    = "qwen"     // Local Qwen via MLX
    case custom  = "custom"
    case claude  = "claude"
    case openai  = "openai"
    case gemini  = "gemini"

    var id: String { rawValue }

    // "Default" would be wrong here: this name also appears in the per-meeting
    // regenerate picker, where Qwen may NOT be the user's default engine.
    var displayName: String {
        switch self {
        case .qwen:   return "Qwen (local)"
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

/// Thrown before making a request when a cloud backend has no API key —
/// beats the cryptic HTTP 401 the API would return for an empty key.
struct LLMNotConfiguredError: LocalizedError {
    let provider: String
    var errorDescription: String? {
        "\(provider) has no API key. Add one in Settings → AI."
    }
}

/// A non-2xx response from a cloud LLM API, with the server's own error
/// message extracted. Claude, OpenAI, and Gemini all use the same
/// `{"error": {"message": …}}` envelope.
struct LLMAPIError: LocalizedError {
    let provider: String
    let statusCode: Int
    let message: String

    var errorDescription: String? {
        switch statusCode {
        case 401, 403:
            return "\(provider): API key rejected (HTTP \(statusCode)). Check the key in Settings → AI."
        case 404:
            return "\(provider): model not found — check the model name in Settings → AI. \(message)"
        case 429:
            return "\(provider): rate limited. Wait a moment and try again."
        case 500...599:
            return "\(provider) is having trouble (HTTP \(statusCode)). Try again shortly."
        default:
            return "\(provider): HTTP \(statusCode) — \(message)"
        }
    }

    static func from(provider: String, statusCode: Int, data: Data) -> LLMAPIError {
        struct Envelope: Decodable {
            struct Err: Decodable { let message: String? }
            let error: Err?
        }
        let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message
            ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
        return LLMAPIError(provider: provider, statusCode: statusCode, message: message)
    }

    /// For streaming paths: the error body arrives on the byte stream itself.
    static func from(
        provider: String, statusCode: Int, bytes: URLSession.AsyncBytes
    ) async -> LLMAPIError {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4096 { break }
            }
        } catch { /* use whatever we got */ }
        return from(provider: provider, statusCode: statusCode, data: data)
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
