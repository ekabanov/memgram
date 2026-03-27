import Foundation

final class ClaudeProvider: LLMProvider {
    let name = "Claude API"
    private let apiKey: String
    private let model = "claude-sonnet-4-6"

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(system: String, user: String) async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
        }
        struct ContentBlock: Decodable { let text: String }
        struct Response: Decodable { let content: [ContentBlock] }

        let body = Request(
            model: model,
            max_tokens: 2048,
            system: system,
            messages: [Message(role: "user", content: user)]
        )
        let response: Response = try await post(body: body)
        return response.content.first?.text ?? ""
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
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
