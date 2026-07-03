import Foundation
import OSLog

private let log = Logger.make("AI")

final class ClaudeProvider: LLMProvider {
    let name: String
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String = LLMProviderStore.defaultClaudeModel) {
        self.apiKey = apiKey
        self.model  = model
        self.name   = "Claude (\(model))"
    }

    func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMNotConfiguredError(provider: "Claude") }

        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
        }
        struct ContentBlock: Decodable { let type: String; let text: String? }
        struct Response: Decodable { let content: [ContentBlock] }

        let body = Request(
            model: model,
            max_tokens: 8192,
            system: system,
            messages: [Message(role: "user", content: user)]
        )
        let response: Response = try await post(body: body)
        // Skip non-text blocks (e.g. thinking) — take the first text block.
        return response.content.first(where: { $0.type == "text" })?.text ?? ""
    }

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard !self.apiKey.isEmpty else {
                        throw LLMNotConfiguredError(provider: "Claude")
                    }
                    struct Message: Encodable { let role: String; let content: String }
                    struct Request: Encodable {
                        let model: String; let max_tokens: Int; let stream: Bool
                        let system: String; let messages: [Message]
                    }
                    let body = Request(
                        model: self.model, max_tokens: 8192, stream: true,
                        system: system,
                        messages: [Message(role: "user", content: user)]
                    )
                    var request = URLRequest(
                        url: URL(string: "https://api.anthropic.com/v1/messages")!,
                        timeoutInterval: 600
                    )
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    guard (200...299).contains(http.statusCode) else {
                        let apiError = await LLMAPIError.from(
                            provider: "Claude", statusCode: http.statusCode, bytes: bytes)
                        log.error("Claude stream failed: \(apiError.localizedDescription)")
                        throw apiError
                    }

                    struct Delta: Decodable { let type: String; let text: String? }
                    struct StreamEvent: Decodable { let type: String; let delta: Delta? }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard json != "[DONE]" else { break }
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(StreamEvent.self, from: data),
                              event.type == "content_block_delta",
                              event.delta?.type == "text_delta",
                              let text = event.delta?.text else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Claude has no embedding API — delegate to local Ollama.
    func embed(text: String) async throws -> [Float] {
        return try await OllamaProvider().embed(text: text)
    }

    private func post<Body: Encodable, Response: Decodable>(body: Body) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)
        log.debug("→ POST \(request.url?.path ?? "?")")
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            log.error("← non-HTTP response from \(request.url?.host ?? "?")")
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let apiError = LLMAPIError.from(provider: "Claude", statusCode: http.statusCode, data: data)
            log.error("← \(apiError.localizedDescription)")
            throw apiError
        }
        log.debug("← HTTP \(http.statusCode), \(data.count) bytes")
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            log.error("JSON decode failed: \(error)")
            throw error
        }
    }
}
