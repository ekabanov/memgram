import SwiftUI

struct ModelDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @State private var selectedModel: WhisperModel = WhisperModelManager.shared.selectedModel
    @State private var downloadError: String?
    @State private var isDownloading = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 480, height: 360)
    }

    private var content: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.blue, .purple)

            VStack(spacing: 8) {
                Text("Download Transcription Model")
                    .font(.title3.bold())
                Text("Memgram uses Whisper to transcribe speech locally.\nNo audio ever leaves your Mac.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if isDownloading {
                downloadingView
            } else {
                modelPicker
            }

            if let error = downloadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(WhisperModel.allCases) { model in
                HStack {
                    Image(systemName: selectedModel == model ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedModel == model ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                            .font(.body)
                        if modelManager.isDownloaded(model) {
                            Text(modelManager.isCoreMLReady(model) ? "Downloaded + CoreML" : "Downloaded")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedModel = model }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var downloadingView: some View {
        VStack(spacing: 10) {
            ProgressView(value: modelManager.downloadProgress)
                .progressViewStyle(.linear)
            HStack {
                Text("\(modelManager.downloadPhase.isEmpty ? "Downloading" : modelManager.downloadPhase)…")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(modelManager.downloadProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if modelManager.isModelReady && !isDownloading {
                Button("Skip") {
                    closeSheet()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            Spacer()
            if isDownloading {
                Button("Cancel") {
                    modelManager.cancelDownload()
                    isDownloading = false
                }
                .buttonStyle(.bordered)
            } else if modelManager.isDownloaded(selectedModel) {
                Button("Use \(selectedModel.rawValue)") {
                    modelManager.selectModel(selectedModel)
                    closeSheet()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Download") {
                    modelManager.selectModel(selectedModel)
                    startDownload()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func startDownload() {
        isDownloading = true
        downloadError = nil
        Task {
            do {
                try await modelManager.downloadSelectedModel()
                await MainActor.run {
                    isDownloading = false
                    closeSheet()
                }
            } catch is CancellationError {
                isDownloading = false
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = error.localizedDescription
                }
            }
        }
    }

    private func closeSheet() {
        UserDefaults.standard.set(true, forKey: "hasShownModelDownload")
        dismiss()
    }
}
