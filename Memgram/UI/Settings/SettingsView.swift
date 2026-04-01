import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "waveform") }
            CalendarSettingsView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            BugReportView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - AI Settings

struct AISettingsTab: View {
    @ObservedObject private var store = LLMProviderStore.shared
    @State private var connectionStatus = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("AI Engine") {
                Picker("Engine", selection: $store.selectedBackend) {
                    ForEach(LLMBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Section(store.selectedBackend.displayName) {
                switch store.selectedBackend {
                case .qwen:   QwenConfigView()
                case .custom: CustomServerConfigView()
                case .claude: APIKeyConfigView(service: "claude", label: "Claude API Key", placeholder: "sk-ant-…")
                case .openai: APIKeyConfigView(service: "openai", label: "OpenAI API Key", placeholder: "sk-…")
                case .gemini: APIKeyConfigView(service: "gemini", label: "Gemini API Key", placeholder: "AIza…")
                }
            }

            Section {
                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection") {
                        Task { await test() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isTesting)
                    if !connectionStatus.isEmpty {
                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundColor(connectionStatus.hasPrefix("Connected") || connectionStatus.hasPrefix("Responded") ? .green : .red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() async {
        isTesting = true
        connectionStatus = ""
        do {
            let reply = try await store.currentProvider.complete(
                system: "You are a test assistant.",
                user: "Reply with exactly: OK"
            )
            let cleanReply = SummaryEngine.shared.stripThinkingTags(reply)
            connectionStatus = cleanReply.hasPrefix("OK")
                ? "Connected"
                : "Responded: \(String(cleanReply.prefix(50)))"
        } catch {
            connectionStatus = "✗ \(error.localizedDescription)"
        }
        isTesting = false
    }
}

// MARK: - Config sub-views

private struct QwenConfigView: View {
    #if canImport(MLXLLM)
    private var modelLabel: String {
        if #available(macOS 14, *) { return QwenLocalProvider.shared.name }
        return "Qwen 3.5 (Local)"
    }
    #else
    private var modelLabel: String { "Qwen 3.5 (Local)" }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(modelLabel, systemImage: "cpu")
                .font(.headline)
            Text("Runs entirely on your Mac using Apple MLX. Model size auto-selected based on RAM (2B / 9B / 27B). Requires Apple Silicon.")
                .font(.body).foregroundColor(.secondary)
            #if canImport(MLXLLM)
            if #available(macOS 14, *) {
                QwenDownloadStatusView()
            } else {
                Label("Requires macOS 14+", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
            }
            #else
            Label("MLX not available in this build", systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
            #endif
        }
    }
}

#if canImport(MLXLLM)
@available(macOS 14, *)
private struct QwenDownloadStatusView: View {
    @ObservedObject private var provider = QwenLocalProvider.shared

    var body: some View {
        if provider.isLoaded {
            Label("Model loaded and ready", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        } else if provider.downloadProgress > 0 && provider.downloadProgress < 1 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: provider.downloadProgress)
                Text("Downloading… \(Int(provider.downloadProgress * 100))%")
                    .font(.caption).foregroundColor(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button("Download Model (~4.5 GB)") { provider.preload() }
                    .buttonStyle(.borderedProminent)
                if let err = provider.loadError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }
        }
    }
}
#endif

private struct CustomServerConfigView: View {
    @ObservedObject private var store = LLMProviderStore.shared
    @State private var apiKey: String = KeychainHelper.load(key: "customServerKey") ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Custom Server", systemImage: "network")
                .font(.headline)
            Text("Any OpenAI-compatible server: LM Studio, vLLM, local Ollama, etc.")
                .font(.body).foregroundColor(.secondary)
            LabeledContent("Server URL") {
                TextField("http://localhost:1234", text: $store.customServerURL)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Model name") {
                TextField("local-model", text: $store.customServerModel)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("API key (optional)") {
                SecureField("leave empty if none", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { newValue in
                        KeychainHelper.save(key: "customServerKey", value: newValue)
                    }
            }
        }
    }
}

private struct APIKeyConfigView: View {
    let service: String
    let label: String
    let placeholder: String
    @State private var key: String

    init(service: String, label: String, placeholder: String) {
        self.service     = service
        self.label       = label
        self.placeholder = placeholder
        _key = State(initialValue: KeychainHelper.load(key: "\(service)APIKey") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: "key")
                .font(.headline)
            SecureField(placeholder, text: $key)
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { newValue in
                    KeychainHelper.save(key: "\(service)APIKey", value: newValue)
                }
        }
    }
}

// MARK: - Recording Settings

struct RecordingSettingsTab: View {
    @ObservedObject private var backendManager = TranscriptionBackendManager.shared
    @ObservedObject private var whisperManager = WhisperModelManager.shared

    var body: some View {
        Form {
            Section("Transcription Engine") {
                Picker("Engine", selection: $backendManager.selectedBackend) {
                    Text(TranscriptionBackend.whisper.displayName).tag(TranscriptionBackend.whisper)
                    #if os(macOS)
                    Text(TranscriptionBackend.parakeet.displayName).tag(TranscriptionBackend.parakeet)
                    #endif
                }
                .pickerStyle(.radioGroup)

                Text(backendManager.selectedBackend.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Whisper Model") {
                LabeledContent("Selected model") {
                    Text(whisperManager.selectedModel.shortName)
                        .foregroundStyle(.secondary)
                }
                Text("Model is automatically selected based on available RAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(backendManager.selectedBackend == .whisper ? 1 : 0.4)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Calendar Settings

struct CalendarSettingsView: View {
    @ObservedObject private var calendar = CalendarManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable Calendar Integration", isOn: Binding(
                    get: { calendar.isEnabled },
                    set: { calendar.setEnabled($0) }
                ))
                Text("When enabled, Memgram will show upcoming calendar events and use event details to improve meeting summaries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if calendar.isEnabled {
                Section("Calendar Access") {
                    switch calendar.authorizationStatus {
                    case .fullAccess:
                        Label("Calendar access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .notDetermined:
                        Button("Grant Calendar Access") {
                            Task { await calendar.requestAccess() }
                        }
                    case .denied, .restricted, .writeOnly:
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Calendar access denied", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("Open System Settings > Privacy & Security > Calendars to grant access.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    @unknown default:
                        Text("Unknown status")
                    }
                }

                if calendar.authorizationStatus == .fullAccess && !calendar.availableCalendars.isEmpty {
                    Section("Calendars to Monitor") {
                        Text("Tap a calendar to include or exclude it. All calendars are monitored by default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(calendar.availableCalendars, id: \.calendarIdentifier) { cal in
                            let isActive = calendar.selectedCalendarIds.isEmpty || calendar.selectedCalendarIds.contains(cal.calendarIdentifier)
                            Button {
                                var ids = calendar.selectedCalendarIds
                                if ids.isEmpty {
                                    ids = Set(calendar.availableCalendars.map(\.calendarIdentifier))
                                }
                                if isActive {
                                    ids.remove(cal.calendarIdentifier)
                                } else {
                                    ids.insert(cal.calendarIdentifier)
                                }
                                if ids.count == calendar.availableCalendars.count { ids = [] }
                                calendar.setSelectedCalendars(ids)
                            } label: {
                                HStack(spacing: 10) {
                                    // Calendar colour dot
                                    Circle()
                                        .fill(Color(cgColor: cal.cgColor))
                                        .frame(width: 10, height: 10)
                                    // Name + source
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cal.title)
                                            .foregroundStyle(isActive ? .primary : .secondary)
                                        Text(cal.source.title)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    // Explicit checkmark — much clearer than a toggle in dark mode
                                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isActive ? Color(cgColor: cal.cgColor) : Color.secondary.opacity(0.4))
                                        .font(.system(size: 18))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Notifications") {
                    Text("Memgram will notify you 1 minute before scheduled meetings so you can start recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sync Settings

struct SyncSettingsTab: View {
    @State private var showResyncConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("iCloud Sync").font(.headline)
                    Text("Meetings are synced across your devices via iCloud. Transcripts and summaries stay in your private CloudKit database.")
                        .font(.body).foregroundColor(.secondary)
                }
            }
            Divider()
            Button("Re-sync from iCloud") {
                showResyncConfirm = true
            }
            .buttonStyle(.bordered)
            .confirmationDialog(
                "Re-sync from iCloud?",
                isPresented: $showResyncConfirm,
                titleVisibility: .visible
            ) {
                Button("Re-sync", role: .destructive) {
                    CloudSyncEngine.shared.resetAndResync()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes all local meetings and re-downloads them from iCloud. Use if meetings appear stuck or out of sync between devices.")
            }
        }
        .padding()
    }
}

// MARK: - Privacy Settings

struct PrivacySettingsTab: View {
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Privacy").font(.headline)
                    Text("Audio is never stored. Memgram discards all audio immediately after transcription. Only text transcripts are saved to your local device.")
                        .font(.body).foregroundColor(.secondary)
                    Text("No data is sent to any server unless you configure a cloud LLM provider in the AI settings.")
                        .font(.body).foregroundColor(.secondary)
                }
            }
            Divider()
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Revert toggle on failure
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }
            Divider()
            Button("Reset Permissions") {
                UserDefaults.standard.removeObject(forKey: "microphonePermissionGranted")
                UserDefaults.standard.removeObject(forKey: "systemAudioPermissionGranted")
                UserDefaults.standard.removeObject(forKey: "hasShownOnboarding")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}
