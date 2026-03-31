import SwiftUI
import OSLog

private let log = Logger.make("UI")

struct MobileSettingsView: View {
    @State private var showBugReport = false
    @State private var showResyncConfirm = false

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

                Section("Sync") {
                    Button("Re-sync from iCloud") {
                        showResyncConfirm = true
                    }
                    .confirmationDialog(
                        "Re-sync from iCloud?",
                        isPresented: $showResyncConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Re-sync", role: .destructive) {
                            Task { @MainActor in
                                CloudSyncEngine.shared.resetAndResync()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This clears the local sync state and re-downloads all meetings from iCloud. Use if meetings appear stuck or out of date.")
                    }
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
