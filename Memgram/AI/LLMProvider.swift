import Foundation

enum LLMBackend: String, CaseIterable, Identifiable {
    case ollama, claude, openai
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .claude: return "Claude API"
        case .openai: return "OpenAI API"
        }
    }
}

protocol LLMProvider {
    var name: String { get }
    func complete(system: String, user: String) async throws -> String
    func embed(text: String) async throws -> [Float]
}
