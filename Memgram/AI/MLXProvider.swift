// Memgram/AI/MLXProvider.swift
import Foundation

/// Connects to a local mlx_lm.server (OpenAI-compatible).
/// Start: python -m mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080
final class MLXProvider: LLMProvider {
    let name = "MLX (local)"
    private let port: Int
    private let modelName: String

    init(port: Int = 8080, modelName: String = "mlx-community/Qwen3-8B-4bit") {
        self.port = port
        self.modelName = modelName
    }

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
            model: modelName,
            messages: [
                Message(role: "system", content: system),
                Message(role: "user", content: user)
            ]
        )
        let response: Response = try await post(path: "/v1/chat/completions", body: body)
        return response.choices.first?.message.content ?? ""
    }

    /// MLX has no embedding API — delegate to local Ollama.
    func embed(text: String) async throws -> [Float] {
        return try await OllamaProvider().embed(text: text)
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
