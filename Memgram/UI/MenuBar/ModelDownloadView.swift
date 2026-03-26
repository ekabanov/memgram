import SwiftUI
import WhisperKit

struct ModelDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @State private var selectedModel: WhisperModel = WhisperModelManager.shared.selectedModel
    @State private var isPrewarming = false
    @State private var prewarmStatus = ""

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

            VStack(spacing: 6) {
                Text("Transcription Model")
                    .font(.title3.bold())
                Text("WhisperKit downloads and caches models automatically on first use.\nAll processing is local — no audio leaves your Mac.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            modelPicker

            if !prewarmStatus.isEmpty {
                Text(prewarmStatus)
                    .font(.caption)
                    .foregroundColor(prewarmStatus.hasPrefix("✓") ? .green : .secondary)
            }
        }
        .padding(16)
    }

    // MARK: - Model picker (grouped)

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
                                Text(model.displayName)
                                    .font(.body)
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
                }
            }
        }
        .frame(maxHeight: 340)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Skip") { closeSheet() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Spacer()
            Button(isPrewarming ? "Loading…" : "Pre-load Model") {
                prewarm()
            }
            .buttonStyle(.bordered)
            .disabled(isPrewarming)
            Button("Use \(selectedModel.rawValue)") {
                modelManager.selectModel(selectedModel)
                closeSheet()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func prewarm() {
        modelManager.selectModel(selectedModel)
        isPrewarming = true
        prewarmStatus = "Downloading and compiling model…"
        Task {
            do {
                _ = try await WhisperKit(model: selectedModel.whisperKitName, verbose: false)
                await MainActor.run {
                    isPrewarming = false
                    prewarmStatus = "✓ Model ready"
                }
            } catch {
                await MainActor.run {
                    isPrewarming = false
                    prewarmStatus = "✗ \(error.localizedDescription)"
                }
            }
        }
    }

    private func closeSheet() {
        UserDefaults.standard.set(true, forKey: "hasShownModelDownload")
        dismiss()
    }
}
