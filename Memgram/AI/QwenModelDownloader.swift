import Foundation
import OSLog

#if canImport(MLXLLM)

/// Downloads Qwen model files directly from Hugging Face's classic HTTPS
/// `resolve/` endpoint into the directory MLX loads from.
///
/// Exists because the hub library's downloader routes large files through the
/// Xet CDN (`xet-bridge`), which stalls to zero bytes on some networks while
/// plain `resolve/` downloads work fine. Rolling our own also buys:
/// - true byte-level progress (Content-Length is present on resolve/)
/// - HTTP-Range resume of partial shards across retries and app restarts
/// - a 60s idle timeout, so a dead transfer becomes a retryable error
///   instead of an eternally frozen progress bar
@available(macOS 14.0, *)
enum QwenModelDownloader {

    private static let log = Logger.make("AI")

    struct RepoFile {
        let name: String
        let size: Int64
    }

    enum DownloadError: LocalizedError {
        case fileListFailed(Int)
        case httpError(String, Int)
        case sizeMismatch(String)

        var errorDescription: String? {
            switch self {
            case .fileListFailed(let code):
                return "Could not fetch model file list from Hugging Face (HTTP \(code))."
            case .httpError(let file, let code):
                return "Download of \(file) failed (HTTP \(code))."
            case .sizeMismatch(let file):
                return "Downloaded \(file) has an unexpected size — retry."
            }
        }
    }

    /// Fetch the repo's file list with byte sizes.
    static func fileList(modelID: String) async throws -> [RepoFile] {
        struct Sibling: Decodable { let rfilename: String; let size: Int64? }
        struct ModelInfo: Decodable { let siblings: [Sibling] }

        let url = URL(string: "https://huggingface.co/api/models/\(modelID)?blobs=true")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.fileListFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        return info.siblings
            .filter { !$0.rfilename.hasPrefix(".") && $0.rfilename != "README.md" }
            .map { RepoFile(name: $0.rfilename, size: $0.size ?? 0) }
    }

    /// Ensure all model files exist in `directory`, downloading what's missing.
    /// `progress` receives the overall byte fraction (0…1).
    static func ensureModel(
        modelID: String,
        into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let files = try await fileList(modelID: modelID)
        let totalBytes = max(files.reduce(0) { $0 + $1.size }, 1)
        log.info("Model \(modelID): \(files.count) files, \(totalBytes / 1_000_000) MB total")

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var doneBytes: Int64 = 0
        for file in files {
            let destination = directory.appendingPathComponent(file.name)
            if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64,
               existing == file.size {
                doneBytes += file.size
                progress(Double(doneBytes) / Double(totalBytes))
                continue
            }

            let base = doneBytes
            try await downloadFile(
                modelID: modelID, file: file, to: destination
            ) { receivedBytes in
                progress(Double(base + receivedBytes) / Double(totalBytes))
            }
            doneBytes += file.size
            progress(Double(doneBytes) / Double(totalBytes))
        }
        log.info("Model \(modelID): all files present")
    }

    /// Download one file with Range-resume and an idle timeout. Retries up to
    /// 3 times, resuming from the persisted `.partial` file each time.
    private static func downloadFile(
        modelID: String,
        file: RepoFile,
        to destination: URL,
        received: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("partial")
        var lastError: Error?

        for attempt in 1...3 {
            do {
                try await downloadAttempt(modelID: modelID, file: file,
                                          partial: partial, received: received)
                // Validate and move into place
                let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? -1
                guard size == file.size else {
                    try? FileManager.default.removeItem(at: partial)
                    throw DownloadError.sizeMismatch(file.name)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                return
            } catch {
                lastError = error
                log.warning("Download attempt \(attempt)/3 for \(file.name) failed: \(error.localizedDescription) — partial data is kept for resume")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                }
            }
        }
        throw lastError ?? DownloadError.httpError(file.name, -1)
    }

    private static func downloadAttempt(
        modelID: String,
        file: RepoFile,
        partial: URL,
        received: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let existingBytes = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0

        var request = URLRequest(
            url: URL(string: "https://huggingface.co/\(modelID)/resolve/main/\(file.name)")!)
        // Idle timeout: no bytes for 60s → error → retry/resume. This is what
        // turns a silently dead transfer into something the UI can act on.
        request.timeoutInterval = 60
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.httpError(file.name, -1)
        }

        var resumedFrom: Int64
        switch http.statusCode {
        case 206:
            resumedFrom = existingBytes
            if existingBytes > 0 {
                log.info("Resuming \(file.name) from \(existingBytes / 1_000_000) MB")
            }
        case 200:
            // Server ignored the range — start over
            resumedFrom = 0
            try? FileManager.default.removeItem(at: partial)
        default:
            throw DownloadError.httpError(file.name, http.statusCode)
        }

        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var buffer = Data(capacity: 1_048_576)
        var written = resumedFrom
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1_048_576 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                received(written)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            received(written)
        }
    }
}
#endif
