import Foundation

/// Connects to any OpenAI-compatible server (LM Studio, Ollama, vLLM, etc.)
final class CustomServerProvider: LLMProvider {
    let name = "Custom Server"
    private let baseURL: String
    private let apiKey: String
    private let modelName: String

    init(baseURL: String = "http://localhost:1234",
         apiKey: String = "",
         modelName: String = "local-model") {
        self.baseURL   = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey    = apiKey
        self.modelName = modelName
    }

    func complete(system: String, user: String) async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable { let model: String; let messages: [Message] }
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        struct Response: Decodable { let choices: [Choice] }

        let body = Request(model: modelName, messages: [
            Message(role: "system", content: system),
            Message(role: "user",   content: user)
        ])
        let response: Response = try await post(path: "/v1/chat/completions", body: body)
        return response.choices.first?.message.content ?? ""
    }

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    struct Message: Encodable { let role: String; let content: String }
                    struct Request: Encodable {
                        let model: String; let messages: [Message]; let stream: Bool
                    }
                    let body = Request(
                        model: self.modelName,
                        messages: [
                            Message(role: "system", content: system),
                            Message(role: "user",   content: user)
                        ],
                        stream: true
                    )
                    guard let url = URL(string: "\(self.baseURL)/v1/chat/completions") else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url, timeoutInterval: 600)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !self.apiKey.isEmpty {
                        request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }

                    struct Delta: Decodable { let content: String? }
                    struct Choice: Decodable { let delta: Delta }
                    struct StreamChunk: Decodable { let choices: [Choice] }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        guard json != "[DONE]" else { break }
                        guard let data = json.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                              let text = chunk.choices.first?.delta.content else { continue }
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

    private func post<B: Encodable, R: Decodable>(path: String, body: B) async throws -> R {
        guard let url = URL(string: "\(baseURL)\(path)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 600)  // 10 min — large models on long transcripts need time
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(R.self, from: data)
    }
}
