import Foundation

final class OllamaProvider: LLMProvider {
    let name = "Ollama"
    private let model: String
    private let baseURL = URL(string: "http://localhost:11434")!

    init(model: String = "llama3.2") {
        self.model = model
    }

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        struct Request: Encodable {
            let model: String
            let prompt: String
            let system: String
            let stream: Bool
        }
        struct Response: Decodable { let response: String }

        let body = Request(model: model, prompt: user, system: system, stream: false)
        let response: Response = try await post(path: "/api/generate", body: body)
        return response.response
    }

    func embed(text: String) async throws -> [Float] {
        struct Request: Encodable { let model: String; let prompt: String }
        struct Response: Decodable { let embedding: [Float] }

        let body = Request(model: "nomic-embed-text", prompt: text)
        let response: Response = try await post(path: "/api/embeddings", body: body)
        return response.embedding
    }

    // MARK: - Model list (for SettingsView picker)

    func listModels() async -> [String] {
        struct Tag: Decodable { let name: String }
        struct Response: Decodable { let models: [Tag] }

        guard let response: Response = try? await get(path: "/api/tags") else { return [] }
        return response.models.map(\.name)
    }

    // MARK: - HTTP helpers

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        let request = URLRequest(url: baseURL.appendingPathComponent(path))
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
