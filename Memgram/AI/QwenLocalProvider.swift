import Foundation
import OSLog
#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon

@available(macOS 14.0, *)
@MainActor
final class QwenLocalProvider: ObservableObject, LLMProvider {
    static let shared = QwenLocalProvider()
    /// Auto-selects the model based on available RAM.
    ///
    /// Peak memory usage measured in production (model weights + KV cache + activations):
    ///  < 24 GB → 4B 4bit  (~5 GB peak)  — safe on 8 GB machines
    ///  24–47 GB → 9B 4bit  (~12 GB peak) — fits on 24/32 GB machines
    ///  ≥ 48 GB → 27B 4bit (~44 GB peak) — requires 48 GB+
    static var modelID: String {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ram >= 48 { return "mlx-community/Qwen3.5-27B-4bit" }
        if ram >= 24 { return "mlx-community/Qwen3.5-9B-MLX-4bit" }
        return "mlx-community/Qwen3.5-4B-MLX-4bit"
    }

    var name: String {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ram >= 48 { return "Qwen 3.5 27B (local)" }
        if ram >= 24 { return "Qwen 3.5 9B (local)" }
        return "Qwen 3.5 4B (local)"
    }

    /// Approximate download size label shown in the popover during model download.
    static var downloadSizeLabel: String {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ram >= 48 { return "~14 GB" }
        if ram >= 24 { return "~4.5 GB" }
        return "~2.2 GB"
    }

    @Published var downloadProgress: Double = 0
    @Published var isLoaded = false
    @Published var loadError: String?

    private var modelContainer: ModelContainer?
    private let log = Logger.make("AI")
    private var loadTask: Task<Void, Error>?
    private init() {}

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        log.debug("complete() called — model loaded: \(self.isLoaded)")
        if modelContainer == nil {
            log.info("Model not loaded yet, loading")
            try await loadModel()
        }
        guard let container = modelContainer else {
            log.error("Model container is nil after load attempt")
            throw QwenError.modelNotLoaded
        }
        // Run inference in a detached task so it always executes off the main actor.
        // This prevents deadlocks when complete() is called through an existential
        // (any LLMProvider) which doesn't guarantee actor hops under minimal concurrency.
        log.debug("complete() — starting generation")
        let start = Date()
        // Use streamResponse() — session.respond() deadlocks with MLX's AsyncMutex
        let response = try await Task.detached(priority: .userInitiated) {
            let session = ChatSession(container, instructions: system,
                                      additionalContext: ["enable_thinking": false])
            var result = ""
            for try await chunk in session.streamResponse(to: user) {
                result += chunk
            }
            return result
        }.value
        let elapsed = Date().timeIntervalSince(start)
        log.info("complete() done in \(String(format: "%.1f", elapsed))s — \(response.count) chars")
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
                    await self.log.debug("stream() — starting token-by-token generation")
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
                    await self.log.debug("stream() — generation complete")
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func embed(text: String) async throws -> [Float] {
        // Qwen local model does not support embeddings.
        // Semantic search requires a cloud provider (Claude, OpenAI, or Gemini) configured in Settings.
        log.debug("embed() called but Qwen does not support embeddings — returning empty")
        return []
    }

    // MARK: - Model loading

    func loadModel() async throws {
        guard !isLoaded else {
            log.debug("Model already loaded, skipping")
            return
        }
        if let existing = loadTask {
            log.info("Download already in progress — waiting for existing task")
            try await existing.value
            return
        }

        log.info("Loading model: \(Self.modelID)")
        loadError = nil
        downloadProgress = 0

        let task = Task<Void, Error> {
            let config = ModelConfiguration(id: Self.modelID, defaultPrompt: "Hello")
            let container: ModelContainer
            do {
                container = try await LLMModelFactory.shared.loadContainer(
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
                        self?.log.debug("Download progress: \(Int(frac * 100))%")
                    }
                }
            } catch {
                // HubApi may fail (e.g. HTTP 503) even when model is cached on disk.
                // Fall back to loading directly from the local cache directory.
                let localDir = config.modelDirectory()
                let hasWeights = FileManager.default.fileExists(
                    atPath: localDir.appendingPathComponent("config.json").path)
                if hasWeights {
                    self.log.warning("Remote load failed (\(error)) — loading from local cache: \(localDir.path)")
                    let localConfig = ModelConfiguration(directory: localDir, defaultPrompt: "Hello")
                    container = try await LLMModelFactory.shared.loadContainer(configuration: localConfig)
                } else {
                    throw error  // model genuinely not downloaded
                }
            }
            await MainActor.run { [weak self] in
                self?.modelContainer = container
                self?.isLoaded = true
                self?.downloadProgress = 1.0
                self?.loadTask = nil
            }
            self.log.info("Model loaded successfully")
        }
        loadTask = task
        do {
            try await task.value
        } catch is CancellationError {
            log.info("Download cancelled")
            downloadProgress = 0
            loadTask = nil
            // Don't set loadError — cancellation is intentional
        } catch {
            log.error("Model load failed: \(error)")
            loadError = error.localizedDescription
            loadTask = nil
            throw error
        }
    }

    /// Release the loaded model from memory. The next summarisation will reload it.
    func unload() {
        guard isLoaded else { return }
        log.info("Unloading Qwen model to free memory")
        modelContainer = nil
        isLoaded = false
        // Keep downloadProgress at 1.0 so settings shows "Ready" after preload+unload.
        // It is only reset to 0 when a fresh download starts in loadModel().
        // Release MLX Metal GPU cache — without this the allocator holds onto
        // the buffers and memory doesn't return to the OS.
        MLX.Memory.clearCache()
        log.info("MLX cache cleared")
    }

    func cancelDownload() {
        log.info("cancelDownload() called — cancelling in-flight load task")
        loadTask?.cancel()
        loadTask = nil
        downloadProgress = 0
        loadError = nil
        // isLoaded intentionally not reset — if model was already loaded, keep it
    }

    func preload() {
        log.info("preload() called")
        Task {
            do {
                // Download and load model weights, then immediately unload.
                // This ensures model files are cached on disk so the first
                // summarisation starts instantly without waiting for a download.
                try await loadModel()
                unload()
                log.info("Preload complete — model files cached, memory freed until first summary")
            } catch {
                self.log.error("preload() failed: \(error)")
                self.loadError = error.localizedDescription
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
