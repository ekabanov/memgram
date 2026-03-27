import SwiftUI

struct PopoverView: View {
    weak var appDelegate: AppDelegate?
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var session = RecordingSession.shared
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @State private var lastError: String?
    @State private var showModelDownload = false

    var body: some View {
        VStack(spacing: 0) {
            headerSection
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

            if session.isRecording && !session.segments.isEmpty {
                Divider()
                LiveTranscriptView(segments: session.segments)
                    .frame(maxHeight: 180)
            } else {
                statusSection
                    .padding(.horizontal, 16)
                Spacer()
            }

            if session.isRecording {
                Divider()
                levelMeterSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                if session.sysLevel == 0 && session.silentSysAudioSeconds > 2 {
                    systemAudioWarning
                        .padding(.horizontal, 16)
                }
            }

            if let error = lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Divider()
            footerSection
                .padding(12)
        }
        .frame(width: 400, height: 340)
        .sheet(isPresented: $permissions.showOnboardingSheet) {
            OnboardingView()
        }
        .sheet(isPresented: $showModelDownload) {
            ModelDownloadView()
        }
        .alert(
            "Interrupted Recording",
            isPresented: Binding(
                get: { !session.interruptedMeetings.isEmpty },
                set: { _ in }
            ),
            presenting: session.interruptedMeetings.first
        ) { meeting in
            Button("Recover") { session.recoverMeeting(meeting) }
            Button("Discard", role: .destructive) { session.discardMeeting(meeting) }
        } message: { meeting in
            Text("\"\(meeting.title)\" was interrupted. Recover it as a completed meeting, or discard it?")
        }
        .onAppear {
            if !modelManager.isModelReady &&
               !UserDefaults.standard.bool(forKey: "hasShownModelDownload") {
                showModelDownload = true
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "waveform.badge.mic")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("Memgram")
                .font(.headline)
            Spacer()
            Button(action: { showModelDownload = true }) {
                Label(modelManager.isModelReady ? modelManager.selectedModel.shortName : "Setup",
                      systemImage: modelManager.isModelReady ? "waveform" : "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(action: { appDelegate?.openMainWindow() }) {
                Label("Open", systemImage: "macwindow")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open main window")
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Quit Memgram")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(spacing: 8) {
            if session.isRecording {
                Image(systemName: "mic.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.red)
                Text(modelManager.isModelReady ? "Recording & transcribing…" : "Recording…")
                    .font(.body)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Ready to record")
                        .font(.body)
                        .foregroundColor(.primary)
                    if !modelManager.isModelReady {
                        Text("Download a model to enable transcription")
                            .font(.caption)
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    } else {
                        Text("Click Start Recording to begin")
                            .font(.caption)
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Level Meters

    private var levelMeterSection: some View {
        VStack(spacing: 4) {
            LevelMeterRow(label: "Mic", level: session.micLevel, color: .blue)
            LevelMeterRow(label: "System", level: session.sysLevel, color: .purple)
        }
    }

    private var systemAudioWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
            Text("System audio silent. Check Settings → Privacy → Screen & System Audio Recording.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Footer

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14, *) {
            SettingsLink {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private var footerSection: some View {
        HStack {
            settingsButton
            .help("Settings")
            permissionsStatus
            Spacer()
            if session.isRecording {
                Button("Stop") { Task { await session.stop() } }
                    .buttonStyle(.bordered)
            } else if !permissions.microphoneGranted {
                Button("Fix Permissions") {
                    Task {
                        let granted = await permissions.requestMicrophonePermission()
                        if !granted { permissions.openSystemPreferences() }
                    }
                }
                .buttonStyle(.bordered)
            } else {
                Button("Start Recording") {
                    lastError = nil
                    Task {
                        do { try await session.start() }
                        catch { lastError = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var permissionsStatus: some View {
        HStack(spacing: 4) {
            permissionDot(granted: permissions.microphoneGranted)
            Text("Mic").font(.caption2).foregroundColor(.secondary)
            permissionDot(granted: permissions.systemAudioGranted)
            Text("System Audio").font(.caption2).foregroundColor(.secondary)
        }
    }

    private func permissionDot(granted: Bool) -> some View {
        Circle()
            .fill(granted ? Color.green : Color.red.opacity(0.7))
            .frame(width: 6, height: 6)
    }
}

// MARK: - Level Meter

struct LevelMeterRow: View {
    let label: String
    let level: Float
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                }
            }
            .frame(height: 6)
        }
    }
}
