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
        // Run inference in a detached task so it always executes off the main actor.
        // This prevents deadlocks when complete() is called through an existential
        // (any LLMProvider) which doesn't guarantee actor hops under minimal concurrency.
        print("[QwenLocal] Creating ChatSession — system prompt: \(system.prefix(80))…")
        let start = Date()
        print("[QwenLocal] Generating response…")
        let response = try await Task.detached(priority: .userInitiated) {
            let session = ChatSession(container, instructions: system)
            return try await session.respond(to: user)
        }.value
        let elapsed = Date().timeIntervalSince(start)
        print("[QwenLocal] ✓ Response generated in \(String(format: "%.1f", elapsed))s — \(response.count) chars")
        return response
    }

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // Load model on main actor if not yet ready
                    if await self.modelContainer == nil {
                        try await self.loadModel()
                    }
                    guard let container = await self.modelContainer else {
                        throw QwenError.modelNotLoaded
                    }
                    print("[QwenLocal] stream() — starting token-by-token generation")
                    let session = ChatSession(
                        container,
                        instructions: system,
                        additionalContext: ["enable_thinking": false]
                    )

                    // Buffer tokens until the <think> block closes, then stream the real response.
                    // If no <think> block appears in the first tokens, stream immediately.
                    var rawAccumulated = ""
                    var pastThinking = false

                    for try await chunk in session.streamResponse(to: user) {
                        rawAccumulated += chunk

                        if pastThinking {
                            // Think block is done — yield every subsequent token directly
                            continuation.yield(chunk)
                        } else if rawAccumulated.contains("</think>") {
                            // Think block just closed — yield everything after it
                            pastThinking = true
                            let afterThink = rawAccumulated
                                .components(separatedBy: "</think>")
                                .dropFirst()
                                .joined(separator: "</think>")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !afterThink.isEmpty {
                                continuation.yield(afterThink)
                            }
                        } else if !rawAccumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .hasPrefix("<think>") && rawAccumulated.count > 10 {
                            // No think block after first tokens — stream normally from here
                            pastThinking = true
                            continuation.yield(rawAccumulated)
                        }
                        // else: still buffering the think block
                    }
                    continuation.finish()
                    print("[QwenLocal] stream() — generation complete")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
                    // Only advance — never go backwards. Multi-shard downloads fire
                    // concurrent callbacks that can arrive out of order.
                    guard let self, frac > self.downloadProgress else { return }
                    self.downloadProgress = frac
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
