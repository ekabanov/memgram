import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 500, height: 360)
    }
}

// MARK: - AI Settings

struct AISettingsTab: View {
    @ObservedObject private var store = LLMProviderStore.shared
    @State private var claudeKey: String = KeychainHelper.load(key: "claudeAPIKey") ?? ""
    @State private var openaiKey: String = KeychainHelper.load(key: "openaiAPIKey") ?? ""
    @State private var ollamaModels: [String] = []
    @State private var connectionStatus: String = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("LLM Backend") {
                Picker("Provider", selection: $store.selectedBackend) {
                    ForEach(LLMBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
            }

            Group {
                if store.selectedBackend == .ollama {
                    Section("Ollama") {
                        Picker("Model", selection: $store.ollamaModel) {
                            if ollamaModels.isEmpty {
                                Text(store.ollamaModel).tag(store.ollamaModel)
                            }
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .onAppear { Task { ollamaModels = await store.fetchOllamaModels() } }
                    }
                } else if store.selectedBackend == .claude {
                    Section("Claude API Key") {
                        SecureField("sk-ant-…", text: $claudeKey)
                            .onChange(of: claudeKey) { newValue in
                                KeychainHelper.save(key: "claudeAPIKey", value: newValue)
                            }
                    }
                } else if store.selectedBackend == .mlx {
                    Section("MLX Server") {
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("8080", value: $store.mlxPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }
                        TextField("Model", text: $store.mlxModel)
                            .textFieldStyle(.roundedBorder)
                        Text("Start: python -m mlx_lm.server --model \(store.mlxModel) --port \(store.mlxPort)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Section("OpenAI API Key") {
                        SecureField("sk-…", text: $openaiKey)
                            .onChange(of: openaiKey) { newValue in
                                KeychainHelper.save(key: "openaiAPIKey", value: newValue)
                            }
                    }
                }
            }

            Section {
                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting)
                    if !connectionStatus.isEmpty {
                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundColor(connectionStatus.hasPrefix("✓") ? .green : .red)
                    }
                }
            }
        }
        .padding()
    }

    private func testConnection() async {
        isTesting = true
        connectionStatus = ""
        let provider = LLMProviderStore.shared.currentProvider
        do {
            let reply = try await provider.complete(
                system: "You are a test assistant.",
                user: "Reply with exactly: OK"
            )
            connectionStatus = reply.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("OK")
                ? "✓ Connected"
                : "✓ Responded: \(reply.prefix(40))"
        } catch {
            connectionStatus = "✗ \(error.localizedDescription)"
        }
        isTesting = false
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
                    Text("Your Privacy")
                        .font(.headline)
                    Text("Audio is never stored. Memgram discards all audio immediately after transcription. Only text transcripts are saved to your local device.")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text("No data is sent to any server unless you configure a cloud LLM provider (Claude API or OpenAI) in the AI settings.")
                        .font(.body)
                        .foregroundColor(.secondary)
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
