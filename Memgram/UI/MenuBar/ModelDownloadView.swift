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
        .frame(width: 500, height: 540)
    }

    private var content: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 36))
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
        .padding(16)
    }

    private struct ModelGroup {
        let title: String
        let models: [WhisperModel]
    }

    private let modelGroups: [ModelGroup] = [
        ModelGroup(title: "English Only", models: [.tinyEn, .baseEn, .smallEn, .mediumEn]),
        ModelGroup(title: "Multilingual", models: [.tiny, .base, .small, .medium]),
        ModelGroup(title: "Large (multilingual)", models: [.largeV2, .largeV3, .largeV3Turbo])
    ]

    private var modelPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(modelGroups, id: \.title) { group in
                    Text(group.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.models) { model in
                            HStack(spacing: 10) {
                                Image(systemName: selectedModel == model ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedModel == model ? .accentColor : Color(NSColor.separatorColor))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)

                            if model != group.models.last {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal, 0)
                }
            }
        }
        .frame(maxHeight: 340)
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
