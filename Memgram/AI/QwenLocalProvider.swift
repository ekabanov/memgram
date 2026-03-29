import Foundation
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon

@available(macOS 14.0, *)
@MainActor
final class QwenLocalProvider: ObservableObject, LLMProvider {
    static let shared = QwenLocalProvider()
    static let modelID = "mlx-community/Qwen3.5-9B-MLX-4bit"

    let name = "Qwen 3.5 9B (local)"

    @Published var downloadProgress: Double = 0
    @Published var isLoaded = false
    @Published var loadError: String?

    private var modelContainer: ModelContainer?
    private var loadTask: Task<Void, Error>?
    private init() {}

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        print("[QwenLocal] complete() called — model loaded: \(isLoaded)")
        if modelContainer == nil {
            print("[QwenLocal] Model not loaded yet, loading…")
            try await loadModel()
        }
        guard let container = modelContainer else {
            print("[QwenLocal] ✗ Model container is nil after load attempt")
            throw QwenError.modelNotLoaded
        }
        print("[QwenLocal] Creating ChatSession — system prompt: \(system.prefix(80))…")
        let session = ChatSession(container, instructions: system)
        let start = Date()
        print("[QwenLocal] Generating response…")
        let response = try await session.respond(to: user)
        let elapsed = Date().timeIntervalSince(start)
        print("[QwenLocal] ✓ Response generated in \(String(format: "%.1f", elapsed))s — \(response.count) chars")
        return response
    }

    func embed(text: String) async throws -> [Float] {
        // Qwen local model does not support embeddings.
        // Semantic search requires a cloud provider (Claude, OpenAI, or Gemini) configured in Settings.
        print("[QwenLocal] ⚠️ embed() called but Qwen does not support embeddings — returning empty")
        return []
    }

    // MARK: - Model loading

    func loadModel() async throws {
        guard !isLoaded else {
            print("[QwenLocal] Model already loaded, skipping")
            return
        }
        loadError = nil
        downloadProgress = 0

        let task = Task<Void, Error> {
            let config = ModelConfiguration(id: Self.modelID, defaultPrompt: "Hello")
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { [weak self] progress in
                let frac = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    self?.downloadProgress = frac
                }
                if Int(frac * 100) % 10 == 0 {
                    print("[QwenLocal] Download progress: \(Int(frac * 100))%")
                }
            }
            await MainActor.run { [weak self] in
                self?.modelContainer = container
                self?.isLoaded = true
                self?.downloadProgress = 1.0
                self?.loadTask = nil
                print("[QwenLocal] ✓ Model loaded successfully")
            }
        }
        loadTask = task
        do {
            try await task.value
        } catch is CancellationError {
            print("[QwenLocal] Download cancelled")
            downloadProgress = 0
            loadTask = nil
            // Don't set loadError — cancellation is intentional
        } catch {
            print("[QwenLocal] ✗ Model load failed: \(error)")
            loadError = error.localizedDescription
            loadTask = nil
            throw error
        }
    }

    func cancelDownload() {
        print("[QwenLocal] cancelDownload() called — cancelling in-flight load task")
        loadTask?.cancel()
        loadTask = nil
        downloadProgress = 0
        loadError = nil
        // isLoaded intentionally not reset — if model was already loaded, keep it
    }

    func preload() {
        print("[QwenLocal] preload() called")
        Task {
            do { try await loadModel() }
            catch {
                print("[QwenLocal] ✗ preload() failed: \(error)")
                loadError = error.localizedDescription
            }
        }
    }
}

@available(macOS 14.0, *)
private enum QwenError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Qwen model is not loaded"
        }
    }
}
#endif
