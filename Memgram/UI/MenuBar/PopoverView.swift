import SwiftUI

struct PopoverView: View {
    weak var appDelegate: AppDelegate?
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var session = RecordingSession.shared
    @ObservedObject private var calendar = CalendarManager.shared
    @ObservedObject private var modelManager = WhisperModelManager.shared
    @ObservedObject private var backendManager = TranscriptionBackendManager.shared
    @ObservedObject private var llmStore = LLMProviderStore.shared
    @State private var lastError: String?

    private var isModelReady: Bool {
        switch backendManager.selectedBackend {
        case .whisper:  return modelManager.isWhisperReady
        case .parakeet: return backendManager.isParakeetReady
        }
    }

    private var isModelLoading: Bool {
        switch backendManager.selectedBackend {
        case .whisper:  return modelManager.isWhisperDownloading
        case .parakeet: return backendManager.isLoading
        }
    }

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
                ScrollView {
                    VStack(spacing: 0) {
                        downloadCards
                        upcomingEventCard
                        statusSection
                            .padding(.horizontal, 16)
                    }
                }
            }

            if session.isRecording {
                Divider()
                levelMeterSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
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
        .frame(width: 400, height: 380)
        .sheet(isPresented: $permissions.showOnboardingSheet) {
            OnboardingView()
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
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            Text("Memgram")
                .font(.headline)
            Spacer()
            Button(action: { appDelegate?.openMainWindow() }) {
                Label("Meetings", systemImage: "rectangle.stack")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open meetings list")
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
                Text(isModelReady ? "Recording & transcribing…" : "Recording…")
                    .font(.body)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Ready to record")
                        .font(.body)
                        .foregroundColor(.primary)
                    Text("Click Start Recording to begin")
                        .font(.caption)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Download Cards

    @ViewBuilder
    private var downloadCards: some View {
        if modelManager.isWhisperDownloading {
            downloadProgressCard(
                icon: "arrow.down.circle",
                iconColor: .blue,
                title: "Setting up Whisper",
                subtitle: "\(modelManager.selectedModel.sizeMB) MB · first run only",
                progress: nil
            )
        }
        if backendManager.isLoading {
            downloadProgressCard(
                icon: "arrow.down.circle",
                iconColor: .indigo,
                title: "Setting up Parakeet",
                subtitle: "~600 MB · ANE model · first run only",
                progress: nil
            )
        }
        #if canImport(MLXLLM)
        if #available(macOS 14, *) {
            QwenDownloadCard()
        }
        #endif
    }

    private func downloadProgressCard(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        progress: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.caption.bold())
                Spacer()
                if let p = progress {
                    Text("\(Int(p * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let p = progress {
                ProgressView(value: p)
                    .tint(iconColor)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(iconColor)
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    // MARK: - Upcoming Event Card

    @ViewBuilder
    private var upcomingEventCard: some View {
        if let event = calendar.upcomingEvent, !session.isRecording {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                    Text("Starting soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(event.startDate, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(event.title ?? "Untitled Event")
                    .font(.headline)
                    .lineLimit(2)
                if let attendees = event.attendees, !attendees.isEmpty {
                    Text(attendees.compactMap(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button("Record This Meeting") {
                    let ctx = CalendarManager.shared.context(for: event)
                    Task { try? await session.start(calendarContext: ctx) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!permissions.microphoneGranted || !permissions.systemAudioGranted || !isModelReady)
                .help(isModelReady ? "" : "\(backendManager.selectedBackend.displayName) is loading — ready shortly")
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
        }
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
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            })
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

    /// LLM selector button — uses SettingsLink so it actually opens the Settings scene.
    @ViewBuilder
    private var llmSettingsButton: some View {
        if #available(macOS 14, *) {
            SettingsLink {
                Label(llmStore.selectedBackend.displayName, systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Button {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(llmStore.selectedBackend.displayName, systemImage: "sparkles")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
                } else if !permissions.microphoneGranted || !permissions.systemAudioGranted {
                    Button("Fix Permissions") {
                        Task {
                            if !permissions.microphoneGranted {
                                let micGranted = await permissions.requestMicrophonePermission()
                                if !micGranted { permissions.openSystemPreferences(); return }
                            }
                            if !permissions.systemAudioGranted {
                                _ = await permissions.requestSystemAudioPermission()
                            }
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
                    .disabled(!isModelReady)
                    .help(isModelReady ? "" : "\(backendManager.selectedBackend.displayName) is loading — ready shortly")
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

// MARK: - Qwen Download Card

#if canImport(MLXLLM)
@available(macOS 14, *)
private struct QwenDownloadCard: View {
    @ObservedObject private var qwen = QwenLocalProvider.shared

    var body: some View {
        let isDownloading = qwen.downloadProgress > 0 && qwen.downloadProgress < 1
        let hasError = qwen.loadError != nil && !qwen.isLoaded

        if isDownloading || hasError {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: hasError ? "exclamationmark.circle" : "arrow.down.circle")
                        .foregroundStyle(hasError ? .red : .purple)
                    Text(hasError ? "Qwen download failed" : "Downloading Qwen 3.5")
                        .font(.caption.bold())
                    Spacer()
                    if isDownloading {
                        Text("\(Int(qwen.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isDownloading {
                    ProgressView(value: qwen.downloadProgress)
                        .tint(.purple)
                    Text("~4.5 GB · runs locally")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let err = qwen.loadError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Button("Retry") { qwen.preload() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
        }
    }
}
#endif

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
