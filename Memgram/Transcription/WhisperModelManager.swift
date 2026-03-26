import Foundation
import Combine
import ZIPFoundation

enum WhisperModel: String, CaseIterable, Identifiable {
    // English-only (faster, English only)
    case tinyEn   = "tiny.en"
    case baseEn   = "base.en"
    case smallEn  = "small.en"
    case mediumEn = "medium.en"
    // Multilingual
    case tiny   = "tiny"
    case base   = "base"
    case small  = "small"
    case medium = "medium"
    // Large (multilingual, no CoreML encoder available)
    case largeV2       = "large-v2"
    case largeV3       = "large-v3"
    case largeV3Turbo  = "large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tinyEn:       return "Tiny EN (75 MB) — English only, fastest"
        case .baseEn:       return "Base EN (142 MB) — English only"
        case .smallEn:      return "Small EN (466 MB) — English only"
        case .mediumEn:     return "Medium EN (1.5 GB) — English only, best EN accuracy"
        case .tiny:         return "Tiny (75 MB) — multilingual"
        case .base:         return "Base (142 MB) — multilingual"
        case .small:        return "Small (466 MB) — multilingual"
        case .medium:       return "Medium (1.5 GB) — multilingual"
        case .largeV2:      return "Large v2 (2.9 GB) — multilingual, high accuracy"
        case .largeV3:      return "Large v3 (3.1 GB) — multilingual, best accuracy"
        case .largeV3Turbo: return "Large v3 Turbo (1.6 GB) — multilingual, fast + accurate"
        }
    }

    var filename: String { "ggml-\(rawValue).bin" }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    /// CoreML encoders only exist for non-large models in the ggerganov/whisper.cpp repo.
    var hasCoreMLEncoder: Bool {
        switch self {
        case .largeV2, .largeV3, .largeV3Turbo: return false
        default: return true
        }
    }

    var coreMLZipURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(rawValue)-encoder.mlmodelc.zip")!
    }

    var coreMLDirectoryName: String { "ggml-\(rawValue)-encoder.mlmodelc" }

    var isEnglishOnly: Bool {
        switch self {
        case .tinyEn, .baseEn, .smallEn, .mediumEn: return true
        default: return false
        }
    }
}

@MainActor
final class WhisperModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    static let shared = WhisperModelManager()

    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadError: String?
    @Published var downloadPhase: String = ""
    @Published var selectedModel: WhisperModel = .mediumEn

    private var downloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, Error>?

    private static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Memgram/models")
    }

    var currentModelURL: URL? {
        let url = Self.modelsDirectory.appendingPathComponent(selectedModel.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var isModelReady: Bool { currentModelURL != nil }

    private override init() {
        if let saved = UserDefaults.standard.string(forKey: "selectedWhisperModel"),
           let model = WhisperModel(rawValue: saved) {
            selectedModel = model
        }
    }

    func selectModel(_ model: WhisperModel) {
        print("[WhisperModelManager] Model selected: \(model.displayName)")
        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhisperModel")
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        let url = Self.modelsDirectory.appendingPathComponent(model.filename)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func isCoreMLReady(_ model: WhisperModel) -> Bool {
        let url = Self.modelsDirectory.appendingPathComponent(model.coreMLDirectoryName)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Download

    func downloadSelectedModel() async throws {
        guard !isDownloading else { return }
        try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        defer { isDownloading = false; downloadPhase = "" }

        // Phase 1: main GGML weights
        print("[WhisperModelManager] Downloading \(selectedModel.displayName) from \(selectedModel.downloadURL)")
        downloadPhase = "Downloading model"
        let tmpURL = try await downloadFile(from: selectedModel.downloadURL)
        let dest = Self.modelsDirectory.appendingPathComponent(selectedModel.filename)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        print("[WhisperModelManager] ✓ Model saved to \(dest.path)")

        // Phase 2: CoreML encoder (not available for large models)
        guard selectedModel.hasCoreMLEncoder else {
            print("[WhisperModelManager] Skipping CoreML encoder (not available for \(selectedModel.rawValue))")
            return
        }
        print("[WhisperModelManager] Downloading CoreML encoder for \(selectedModel.rawValue)")
        downloadProgress = 0
        downloadPhase = "Downloading CoreML encoder"
        let coreMLZipTmp = try await downloadFile(from: selectedModel.coreMLZipURL)
        defer { try? FileManager.default.removeItem(at: coreMLZipTmp) }
        let coreMLDest = Self.modelsDirectory.appendingPathComponent(selectedModel.coreMLDirectoryName)
        try? FileManager.default.removeItem(at: coreMLDest)
        try FileManager.default.unzipItem(at: coreMLZipTmp, to: Self.modelsDirectory)
        print("[WhisperModelManager] ✓ CoreML encoder ready at \(coreMLDest.path)")
    }

    private func downloadFile(from url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { cont in
            downloadContinuation = cont
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            downloadTask = session.downloadTask(with: url)
            downloadTask?.resume()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadContinuation?.resume(throwing: CancellationError())
        downloadContinuation = nil
        isDownloading = false
        downloadPhase = ""
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in self.downloadProgress = progress }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("memgram_model_\(UUID().uuidString).bin")
        try? FileManager.default.moveItem(at: location, to: stable)
        Task { @MainActor in
            self.downloadContinuation?.resume(returning: stable)
            self.downloadContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.downloadContinuation?.resume(throwing: error)
            self.downloadContinuation = nil
            self.downloadError = error.localizedDescription
        }
    }
}
