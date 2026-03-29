import Foundation
import OSLog

private let log = Logger.make("AI")

final class GeminiProvider: LLMProvider {
    let name = "Gemini"
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String = "gemini-2.0-flash") {
        self.apiKey = apiKey
        self.model  = model
    }

    func complete(system: String, user: String) async throws -> String {
        struct Part: Codable { let text: String }
        struct Content: Codable { let parts: [Part] }
        struct SystemInstruction: Encodable { let parts: [Part] }
        struct Request: Encodable {
            let systemInstruction: SystemInstruction
            let contents: [ContentItem]
            struct ContentItem: Encodable {
                let role: String
                let parts: [Part]
            }
        }
        struct Candidate: Decodable { let content: Content }
        struct Response: Decodable { let candidates: [Candidate] }

        let body = Request(
            systemInstruction: .init(parts: [Part(text: system)]),
            contents: [Request.ContentItem(role: "user", parts: [Part(text: user)])]
        )
        let response: Response = try await post(body: body)
        return response.candidates.first?.content.parts.first?.text ?? ""
    }

    func embed(text: String) async throws -> [Float] {
        try await OllamaProvider().embed(text: text)
    }

    private func post<B: Encodable, R: Decodable>(body: B) async throws -> R {
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            log.error("JSON decode failed: \(error)")
            throw error
        }
    }
}
