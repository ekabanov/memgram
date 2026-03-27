import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
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
            ForEach(LLMBackendCategory.allCases, id: \.rawValue) { category in
                Section(category.rawValue) {
                    ForEach(LLMBackend.allCases.filter { $0.category == category }) { backend in
                        ProviderRow(backend: backend)
                            .tag(backend)
                    }
                }
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
                case .ollama: OllamaConfigView()
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
            var cleanReply = reply
            if let closeRange = cleanReply.range(of: "</think>", options: .caseInsensitive) {
                cleanReply = String(cleanReply[closeRange.upperBound...])
            } else if let openRange = cleanReply.range(of: "<think>", options: .caseInsensitive) {
                cleanReply = String(cleanReply[..<openRange.lowerBound])
            }
            cleanReply = cleanReply.trimmingCharacters(in: .whitespacesAndNewlines)
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

private struct OllamaConfigView: View {
    @ObservedObject private var store = LLMProviderStore.shared
    @State private var models: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ollama", systemImage: "server.rack")
                .font(.headline)
            Text("Requires Ollama running locally (ollama.ai). Supports any installed model.")
                .font(.body).foregroundColor(.secondary)
            Picker("Model", selection: $store.ollamaModel) {
                if models.isEmpty { Text(store.ollamaModel).tag(store.ollamaModel) }
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .onAppear { Task { models = await store.fetchOllamaModels() } }
        }
    }
}

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
