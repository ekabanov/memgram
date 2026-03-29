import SwiftUI

struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var steps = ""
    @State private var isSubmitting = false
    @State private var submittedURL: String?
    @State private var errorMessage: String?
    @State private var builtPayload: BugReportPayload?
    @State private var logPreview: String = "Loading logs…"
    @State private var showLogPreview = false

    var body: some View {
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
                .background(Color(NSColor.textBackgroundColor))
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
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Submitting…" : "Submit Report") {
                    Task { await submit() }
                }
                .keyboardShortcut(.return)
                .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting || submittedURL != nil)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { await loadLogPreview() }
    }

    private func loadLogPreview() async {
        let payload = await BugReportPayloadBuilder.build()
        builtPayload = payload
        let lines = payload.logs.suffix(20).map { "[\($0.category)] \($0.level): \($0.message)" }
        let header = """
        App: \(payload.appVersion) | macOS: \(payload.macosVersion)
        Whisper: \(payload.whisperModel) | LLM: \(payload.llmBackend)
        Meetings: \(payload.meetingsMetadata.count) | Crash log: \(payload.crashLog != nil ? "yes" : "no")
        Last \(payload.logs.count) log entries (showing 20):

        """
        logPreview = header + lines.joined(separator: "\n")
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
