import SwiftUI
import WhisperKit

struct ModelDownloadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @State private var isPrewarming = false
    @State private var prewarmStatus = ""

    private var model: WhisperModel { modelManager.autoSelectedModel }
    private var ramLabel: String {
        let gb = WhisperModelManager.ramGB
        return String(format: "%.0f GB RAM detected", gb)
    }

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer.padding(16)
        }
        .frame(width: 460, height: 340)
    }

    private var content: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.blue, .purple)

            VStack(spacing: 6) {
                Text("Transcription Language")
                    .font(.title3.bold())
                Text("Memgram transcribes entirely on your Mac.\nNo audio ever leaves your device.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Language selector
            Picker("Language", selection: $modelManager.preferMultilingual) {
                Text("English").tag(false)
                Text("Multilingual").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            // Auto-selected model info
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text(ramLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Model: **\(model.shortName)** (\(model.sizeMB) MB)")
                    .font(.body)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            if !prewarmStatus.isEmpty {
                Text(prewarmStatus)
                    .font(.caption)
                    .foregroundColor(prewarmStatus.hasPrefix("✓") ? .green : .secondary)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Skip") { closeSheet() }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Spacer()
            Button(isPrewarming ? "Loading…" : "Pre-load Model") { prewarm() }
                .buttonStyle(.bordered)
                .disabled(isPrewarming)
            Button("Done") { closeSheet() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func prewarm() {
        isPrewarming = true
        prewarmStatus = "Downloading and compiling…"
        Task {
            do {
                _ = try await WhisperKit(model: model.whisperKitName, verbose: false, logLevel: .none)
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
