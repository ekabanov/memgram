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

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    struct GPart: Encodable { let text: String }
                    struct GSystemInstruction: Encodable { let parts: [GPart] }
                    struct GContentItem: Encodable { let role: String; let parts: [GPart] }
                    struct GRequest: Encodable {
                        let systemInstruction: GSystemInstruction
                        let contents: [GContentItem]
                    }
                    let body = GRequest(
                        systemInstruction: .init(parts: [GPart(text: system)]),
                        contents: [GContentItem(role: "user", parts: [GPart(text: user)])]
                    )
                    let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(self.model):streamGenerateContent?key=\(self.apiKey)&alt=sse"
                    guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
                    var request = URLRequest(url: url, timeoutInterval: 600)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }

                    struct RPart: Decodable { let text: String }
                    struct RContent: Decodable { let parts: [RPart] }
                    struct RCandidate: Decodable { let content: RContent }
                    struct GStreamEvent: Decodable { let candidates: [RCandidate] }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard let data = json.data(using: .utf8),
                              let event = try? JSONDecoder().decode(GStreamEvent.self, from: data),
                              let text = event.candidates.first?.content.parts.first?.text else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
        log.debug("→ POST \(request.url?.path ?? "?")")
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            log.error("← non-HTTP response from \(request.url?.host ?? "?")")
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
            log.error("← HTTP \(http.statusCode) from \(request.url?.host ?? "?"): \(snippet)")
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
