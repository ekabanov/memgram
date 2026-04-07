import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct BugReportView: View {
    @State private var description = ""
    @State private var steps = ""
    @State private var isSubmitting = false
    @State private var isSavingLogs = false
    @State private var submittedURL: String?
    @State private var errorMessage: String?
    @State private var builtPayload: BugReportPayload?
    @State private var logPreview: String = "Loading logs…"
    @State private var showLogPreview = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Report a Bug")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What happened?").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $description)
                        .frame(minHeight: 80, maxHeight: 120)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Steps to reproduce (optional)").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $steps)
                        .frame(minHeight: 40, maxHeight: 80)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }

                DisclosureGroup("What will be sent", isExpanded: $showLogPreview) {
                    ScrollView {
                        Text(logPreview)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    #if os(macOS)
                    .background(Color(NSColor.textBackgroundColor))
                    #else
                    .background(Color(UIColor.secondarySystemBackground))
                    #endif
                    .cornerRadius(4)
                    Text("Transcript and summary content are never included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let url = submittedURL {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Report submitted!").font(.subheadline).bold()
                        if let dest = URL(string: url) {
                            Link(url, destination: dest)
                                .font(.caption)
                        }
                    }
                }

                HStack {
                    Button(isSavingLogs ? "Saving…" : "Save Logs…") {
                        Task { await saveLogs() }
                    }
                    .disabled(isSavingLogs)
                    Spacer()
                    Button(isSubmitting ? "Submitting…" : "Submit Report") {
                        Task { await submit() }
                    }
                    .keyboardShortcut(.return)
                    .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting || submittedURL != nil)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .task { await loadLogPreview() }
    }

    private func loadLogPreview() async {
        let payload = await BugReportPayloadBuilder.build()
        builtPayload = payload
        let lines = payload.logs.suffix(20).map { "[\($0.category)] \($0.level): \($0.message)" }
        let header = """
        App: \(payload.appVersion) | OS: \(payload.macosVersion)
        Whisper: \(payload.whisperModel ?? "n/a") | LLM: \(payload.llmBackend ?? "n/a")
        Meetings: \(payload.meetingsMetadata.count) | Crash log: \(payload.crashLog != nil ? "yes" : "no")
        Last \(payload.logs.count) log entries (showing 20):

        """
        logPreview = header + lines.joined(separator: "\n")
    }

    private func saveLogs() async {
        isSavingLogs = true
        defer { isSavingLogs = false }

        let payload: BugReportPayload
        if let cached = builtPayload {
            payload = cached
        } else {
            payload = await BugReportPayloadBuilder.build()
            builtPayload = payload
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "memgram-logs-\(formattedDate()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
        #elseif os(iOS)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memgram-logs-\(formattedDate()).json")
        try? data.write(to: tempURL)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        // Present on the topmost view controller (handles sheets)
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(activityVC, animated: true)
        #endif
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            let payload: BugReportPayload
            if let cached = builtPayload {
                payload = cached
            } else {
                payload = await BugReportPayloadBuilder.build()
            }
            let result = try await BugReportSubmitter.submit(
                payload: payload,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                steps: steps.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            submittedURL = result.issueURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
