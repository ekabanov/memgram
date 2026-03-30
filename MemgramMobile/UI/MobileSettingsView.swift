import SwiftUI
import OSLog

private let log = Logger.make("UI")

struct MobileSettingsView: View {
    @State private var showBugReport = false

    var body: some View {
        NavigationStack {
            Form {
                Section("About") {
                    LabeledContent("Version") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    }
                    LabeledContent("Build") {
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                    }
                }

                Section("Privacy") {
                    Label("Audio is never stored. Only text transcripts are saved.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Help") {
                    Button("Report a Bug") {
                        showBugReport = true
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showBugReport) {
                NavigationStack {
                    BugReportView()
                        .navigationTitle("Bug Report")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { showBugReport = false }
                            }
                        }
                }
            }
        }
    }
}
