import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            CalendarSettingsView()
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 500)
    }
}

// MARK: - AI Settings

struct AISettingsTab: View {
    @ObservedObject private var store = LLMProviderStore.shared
    @State private var connectionStatus = ""
    @State private var isTesting = false

    var body: some View {
        HStack(spacing: 0) {
            providerSidebar
                .frame(width: 190)
            Divider()
            VStack(spacing: 0) {
                configPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                testBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Sidebar

    private var providerSidebar: some View {
        List(selection: Binding(
            get: { store.selectedBackend },
            set: { store.selectedBackend = $0 }
        )) {
            ForEach(LLMBackend.allCases) { backend in
                ProviderRow(backend: backend)
                    .tag(backend)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Config panel

    @ViewBuilder
    private var configPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch store.selectedBackend {
                case .qwen:   QwenConfigView()
                case .custom: CustomServerConfigView()
                case .claude: APIKeyConfigView(service: "claude", label: "Claude API Key", placeholder: "sk-ant-…")
                case .openai: APIKeyConfigView(service: "openai", label: "OpenAI API Key", placeholder: "sk-…")
                case .gemini: APIKeyConfigView(service: "gemini", label: "Gemini API Key", placeholder: "AIza…")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Test bar

    private var testBar: some View {
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

// MARK: - Sidebar row

private struct ProviderRow: View {
    let backend: LLMBackend

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(backend.displayName)
                .font(.body)
            Text(backend.badge)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Config sub-views

private struct QwenConfigView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Qwen 3.5 9B (Local)", systemImage: "cpu")
                .font(.headline)
            Text("Runs entirely on your Mac using Apple MLX. Downloads ~4.5 GB on first use. Requires Apple Silicon.")
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

// MARK: - Privacy Settings

struct PrivacySettingsTab: View {
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
