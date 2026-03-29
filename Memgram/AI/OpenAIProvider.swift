import Foundation
import OSLog

private let log = Logger.make("AI")

final class OpenAIProvider: LLMProvider {
    let name = "OpenAI API"
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(system: String, user: String) async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            let model: String
            let messages: [Message]
        }
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        struct Response: Decodable { let choices: [Choice] }

        let body = Request(
            model: "gpt-4o-mini",
            messages: [
                Message(role: "system", content: system),
                Message(role: "user", content: user)
            ]
        )
        let response: Response = try await post(path: "/v1/chat/completions", body: body)
        return response.choices.first?.message.content ?? ""
    }

    func embed(text: String) async throws -> [Float] {
        struct Request: Encodable { let model: String; let input: String }
        struct EmbeddingData: Decodable { let embedding: [Float] }
        struct Response: Decodable { let data: [EmbeddingData] }

        let body = Request(model: "text-embedding-3-small", input: text)
        let response: Response = try await post(path: "/v1/embeddings", body: body)
        return response.data.first?.embedding ?? []
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.openai.com\(path)")!, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        log.debug("→ POST \(request.url?.path ?? "?", privacy: .public)")
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            log.error("← non-HTTP response from \(request.url?.host ?? "?", privacy: .public)")
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
            log.error("← HTTP \(http.statusCode) from \(request.url?.host ?? "?", privacy: .public): \(snippet, privacy: .public)")
            throw URLError(.badServerResponse)
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
