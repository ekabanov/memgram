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
    /// Qwen 3.6 only ships 27B (dense) and 35B-A3B (MoE) — there is no small
    /// 3.6 model, so the lower tiers stay on Qwen 3.5.
    ///
    /// Peak memory usage (model weights + KV cache + activations):
    ///  < 16 GB → 3.5 4B 4bit  (~5 GB peak)  — safe on 8 GB machines
    ///  16–47 GB → 3.5 9B 4bit (~12 GB peak) — fits on 16/24/32 GB machines
    ///  ≥ 48 GB → 3.6 27B 4bit (~16 GB weights, dense — best summary quality;
    ///            preferred over 35B-A3B MoE after real-world comparison)
    static var modelID: String {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ram >= 48 { return "mlx-community/Qwen3.6-27B-4bit" }
        if ram >= 16 { return "mlx-community/Qwen3.5-9B-MLX-4bit" }
        return "mlx-community/Qwen3.5-4B-MLX-4bit"
    }

    var name: String {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ram >= 48 { return "Qwen 3.6 27B (local)" }
        if ram >= 16 { return "Qwen 3.5 9B (local)" }
        return "Qwen 3.5 4B (local)"
    }

    /// Approximate download size label shown in the popover during model download.
    static var downloadSizeLabel: String {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ram >= 48 { return "~16 GB" }
        if ram >= 16 { return "~4.5 GB" }
        return "~2.2 GB"
    }

    @Published var downloadProgress: Double = 0
    /// True only while a GENUINE first-time download is running — cached
    /// weight loads never set this, so the UI can't flash fake download cards.
    @Published var isDownloading = false
    /// True when a running download hasn't moved for a while (stalled HTTP
    /// transfer — Hugging Face throttling or a dead connection). Cleared as
    /// soon as bytes flow again. Surfaced in the download card with a Retry.
    @Published var downloadStalled = false
    @Published var isLoaded = false
    @Published var loadError: String?

    private var lastProgressAt = Date()
    private var lastDiskBytes: Int64 = 0
    private var stallWatchdog: Task<Void, Never>?

    /// Expected on-disk size of the current tier's weights. Used to derive
    /// progress from disk growth: HF's CDN often returns no Content-Length for
    /// LFS/Xet shards, so HubApi's Progress only ticks when a WHOLE multi-GB
    /// shard completes — the bar would sit at 0% for minutes, then leap.
    private static var expectedDownloadBytes: Int64 {
        let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if ram >= 48 { return 16_100_000_000 }
        if ram >= 16 { return 4_500_000_000 }
        return 2_200_000_000
    }

    /// Everywhere download bytes can land: the materialized model directory
    /// (incl. its .cache metadata) and the hub client's staging cache
    /// (<Caches>/huggingface/hub/models--org--name).
    private static func downloadDirectories() -> [URL] {
        var dirs = [ModelConfiguration(id: modelID, defaultPrompt: "Hello").modelDirectory()]
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let hubName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
            dirs.append(caches.appendingPathComponent("huggingface/hub/\(hubName)"))
        }
        return dirs
    }

    nonisolated private static func directoryBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Persisted per model ID: has this model ever fully downloaded?
    /// Keying by ID means a RAM-tier change shows real progress again.
    private var hasCompletedDownload: Bool {
        get { UserDefaults.standard.bool(forKey: "qwenDownloadCompleted_\(Self.modelID)") }
        set { UserDefaults.standard.set(newValue, forKey: "qwenDownloadCompleted_\(Self.modelID)") }
    }

    private var modelContainer: ModelContainer?
    private let log = Logger.make("AI")
    private var loadTask: Task<Void, Error>?

    // MARK: - Generation gate
    //
    // MLX is not safe against concurrent GPU work on the same state: two
    // generations at once, or unload()/clearCache() during a generation,
    // aborts with a Metal "encoding in progress" assertion (app freeze in
    // release). All generation and unload work is therefore serialized
    // through this FIFO gate. State lives on the main actor (class is
    // @MainActor), so no additional locking is needed.
    private var generationInProgress = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    private var unloadRequested = false

    /// Wait until no other generation is running, then take the gate.
    private func acquireGeneration() async {
        if generationInProgress {
            log.info("Generation gate busy — queueing (\(self.generationWaiters.count) already waiting)")
        }
        while generationInProgress {
            await withCheckedContinuation { generationWaiters.append($0) }
        }
        generationInProgress = true
    }

    /// Release the gate: wake the next waiter, or perform a deferred unload.
    private func releaseGeneration() {
        generationInProgress = false
        if !generationWaiters.isEmpty {
            generationWaiters.removeFirst().resume()
        } else if unloadRequested {
            unloadRequested = false
            performUnload()
        }
    }

    private init() {
        // A previously-downloaded model starts at 1.0 ("Ready") — reloading
        // cached weights is not a download and must not animate a bar.
        downloadProgress = hasCompletedDownload ? 1.0 : 0
    }

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        log.debug("complete() called — model loaded: \(self.isLoaded)")
        await acquireGeneration()
        defer { releaseGeneration() }
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
                // Serialize against other generations and unloads — concurrent
                // MLX GPU work aborts with a Metal assertion.
                await self.acquireGeneration()
                do {
                    // Load model on main actor if not yet ready
                    if await self.modelContainer == nil {
                        try await self.loadModel()
                    }
                    guard let container = await self.modelContainer else {
                        throw QwenError.modelNotLoaded
                    }
                    await self.log.debug("stream() — starting token-by-token generation")
                    let generationStart = Date()
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
                    let elapsed = Date().timeIntervalSince(generationStart)
                    await self.log.info("stream() — generation complete in \(String(format: "%.1f", elapsed))s (\(rawAccumulated.count) chars)")
                } catch {
                    continuation.finish(throwing: error)
                }
                await self.releaseGeneration()
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
        // Progress is only published for a GENUINE first-time download.
        // Reloading cached weights (the common case — the model is unloaded
        // after every summary) also fires Hub progress callbacks as files are
        // verified; publishing those made a fake "Downloading 0%→100%" card
        // flash on every summarisation.
        let firstDownload = !hasCompletedDownload
        if firstDownload {
            downloadProgress = 0
            isDownloading = true
            startStallWatchdog()
        }

        let task = Task<Void, Error> {
            // Download via our own resolve/-endpoint downloader (byte progress,
            // Range resume, idle timeout) — the hub library's Xet transport
            // stalls to zero on some networks. MLX then loads purely from disk.
            let localDir = ModelConfiguration(id: Self.modelID, defaultPrompt: "Hello").modelDirectory()
            let progressSink: @Sendable (Double) -> Void = { frac in
                Task { @MainActor [weak self] in
                    guard let self, frac > self.downloadProgress else { return }
                    self.downloadProgress = min(frac, 0.999)
                    self.lastProgressAt = Date()
                    if self.downloadStalled {
                        self.downloadStalled = false
                        self.log.info("Qwen download resumed at \(Int(frac * 100))%")
                    }
                }
            }

            // A previously-completed model must load OFFLINE — no file-list
            // round-trip. ensureModel runs only when the model was never fully
            // downloaded or its files went missing.
            let configPresent = FileManager.default.fileExists(
                atPath: localDir.appendingPathComponent("config.json").path)
            if firstDownload || !configPresent {
                try await QwenModelDownloader.ensureModel(
                    modelID: Self.modelID, into: localDir, progress: progressSink)
            }

            let localConfig = ModelConfiguration(directory: localDir, defaultPrompt: "Hello")
            let container: ModelContainer
            do {
                container = try await LLMModelFactory.shared.loadContainer(configuration: localConfig)
            } catch {
                // Self-heal: a "completed" model with missing/corrupt files
                // (manually cleared cache, interrupted move) — re-verify every
                // file against the repo manifest and load again.
                self.log.warning("Local model load failed (\(error)) — re-verifying files against the repo manifest")
                try await QwenModelDownloader.ensureModel(
                    modelID: Self.modelID, into: localDir, progress: progressSink)
                container = try await LLMModelFactory.shared.loadContainer(configuration: localConfig)
            }
            await MainActor.run { [weak self] in
                self?.modelContainer = container
                self?.isLoaded = true
                self?.downloadProgress = 1.0
                self?.isDownloading = false
                self?.downloadStalled = false
                self?.hasCompletedDownload = true
                self?.loadTask = nil
            }
            self.log.info("Model loaded successfully")
        }
        loadTask = task
        do {
            try await task.value
        } catch is CancellationError {
            log.info("Download cancelled")
            downloadProgress = hasCompletedDownload ? 1.0 : 0
            isDownloading = false
            loadTask = nil
            // Don't set loadError — cancellation is intentional
        } catch {
            log.error("Model load failed: \(error)")
            loadError = error.localizedDescription
            isDownloading = false
            downloadStalled = false
            loadTask = nil
            throw error
        }
    }

    /// Release the loaded model from memory. The next summarisation will reload it.
    /// Deferred automatically if a generation is running — freeing MLX buffers
    /// mid-generation aborts with a Metal assertion.
    func unload() {
        guard isLoaded else { return }
        if generationInProgress {
            log.info("Unload requested during generation — deferring")
            unloadRequested = true
            return
        }
        performUnload()
    }

    /// The actual unload. Callers must ensure no generation is in flight
    /// (either the gate is free, or the caller holds the gate).
    private func performUnload() {
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
        downloadProgress = hasCompletedDownload ? 1.0 : 0
        isDownloading = false
        downloadStalled = false
        loadError = nil
        // isLoaded intentionally not reset — if model was already loaded, keep it
    }

    /// Drives progress from DISK GROWTH and flags genuine stalls.
    ///
    /// HubApi's Progress callback is useless mid-shard when the CDN sends no
    /// Content-Length (common for LFS/Xet): it only ticks when a whole
    /// multi-GB file completes. Bytes on disk are the ground truth — they
    /// grow smoothly while the transfer is alive and freeze when it's dead.
    private func startStallWatchdog() {
        lastProgressAt = Date()
        lastDiskBytes = 0
        downloadStalled = false
        stallWatchdog?.cancel()
        stallWatchdog = Task { @MainActor [weak self] in
            while let self, self.isDownloading, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard self.isDownloading else { break }

                let dirs = Self.downloadDirectories()
                let bytes = await Task.detached(priority: .utility) {
                    dirs.map(Self.directoryBytes).reduce(0, +)
                }.value

                if bytes > self.lastDiskBytes {
                    self.lastDiskBytes = bytes
                    self.lastProgressAt = Date()
                    if self.downloadStalled {
                        self.downloadStalled = false
                        self.log.info("Qwen download resumed (disk at \(bytes / 1_000_000) MB)")
                    }
                    // Never go backwards; cap below 1.0 — completion is set by
                    // the load success path, not the estimate.
                    let diskFrac = min(Double(bytes) / Double(Self.expectedDownloadBytes), 0.99)
                    if diskFrac > self.downloadProgress {
                        self.downloadProgress = diskFrac
                    }
                }

                let quiet = Date().timeIntervalSince(self.lastProgressAt)
                if quiet > 60 && !self.downloadStalled {
                    self.downloadStalled = true
                    self.log.warning("Qwen download stalled — no disk growth for \(Int(quiet))s at \(Int(self.downloadProgress * 100))% (\(bytes / 1_000_000) MB on disk)")
                }
            }
        }
    }

    func preload() {
        log.info("preload() called")
        Task {
            // Hold the generation gate for the whole load→verify→unload cycle.
            // Without it, a summarization that starts mid-preload (e.g. the
            // RemoteMeetingProcessor summary janitor at launch) shares the same
            // loadTask and begins generating — and preload's unload then frees
            // the MLX buffers mid-generation (Metal assertion, app freeze).
            await acquireGeneration()
            defer { releaseGeneration() }
            do {
                // Download and load model weights, then immediately unload.
                // This ensures model files are cached on disk so the first
                // summarisation starts instantly without waiting for a download.
                try await loadModel()
                if generationWaiters.isEmpty {
                    performUnload()
                    log.info("Preload complete — model files cached, memory freed until first summary")
                } else {
                    // A generation queued up behind us — keep the model loaded
                    // instead of unloading just for it to reload seconds later.
                    log.info("Preload complete — model kept loaded for a queued generation")
                }
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
