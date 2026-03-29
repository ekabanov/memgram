# AI Settings Redesign + Download Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sidebar AI settings with a single-page form, remove Ollama, add Qwen download cancellation and retry, and show Qwen/Whisper download progress in the main popover.

**Architecture:** Infrastructure changes first (LLMBackend enum, QwenLocalProvider cancel, WhisperModelManager state), then UI on top (settings redesign, popover cards). No new files — all changes are targeted edits to existing files.

**Tech Stack:** SwiftUI Form, WhisperKit ModelStateCallback, MLX MLXLLM, AppKit/Combine.

---

## File Structure

| File | Change |
|------|--------|
| `Memgram/AI/LLMProvider.swift` | Remove `.ollama` case + all switch arms that reference it |
| `Memgram/AI/LLMProviderStore.swift` | Remove ollamaModel/fetchOllamaModels, add Qwen auto-cancel in didSet |
| `Memgram/AI/QwenLocalProvider.swift` | Add `loadTask`, `cancelDownload()`, retry-safe `loadModel()` |
| `Memgram/Transcription/WhisperModelManager.swift` | Add `@Published var isWhisperDownloading: Bool` |
| `Memgram/Transcription/TranscriptionEngine.swift` | Pass `modelStateCallback` to WhisperKit init to drive `isWhisperDownloading` |
| `Memgram/UI/Settings/SettingsView.swift` | Replace `AISettingsTab` sidebar layout with Form + Picker, shrink window |
| `Memgram/UI/MenuBar/PopoverView.swift` | Add Qwen and Whisper download cards in idle area |

---

## Task 1: Remove Ollama from LLMBackend Enum

**Files:**
- Modify: `Memgram/AI/LLMProvider.swift`

- [ ] **Step 1: Remove `.ollama` case and all its switch arms**

Read the file, then apply these changes:

Remove from the `LLMBackend` enum:
```swift
case ollama  = "ollama"
```

In `displayName`:
```swift
// remove:
case .ollama: return "Ollama"
```

In `category` — change the `.qwen, .ollama` grouping to just `.qwen`:
```swift
// before:
case .qwen, .ollama:            return .freeLocal
// after:
case .qwen:                     return .freeLocal
```

In `badge` — change `.qwen, .ollama` to just `.qwen`:
```swift
// before:
case .qwen, .ollama: return "Free"
// after:
case .qwen: return "Free"
```

In `isConfigured` — change `.qwen, .ollama` to just `.qwen`:
```swift
// before:
case .qwen, .ollama:
    return true
// after:
case .qwen:
    return true
```

Also remove `LLMBackendCategory` entirely — the categories were only used in the sidebar which is being removed. The enum is no longer referenced once the sidebar is gone.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20`

Expected: build errors for `ollama` references in `LLMProviderStore.swift` — that's correct, we fix those next.

- [ ] **Step 3: Commit**

```bash
git add Memgram/AI/LLMProvider.swift
git commit -m "feat: remove Ollama from LLMBackend — Custom Server covers all self-hosted use cases"
```

---

## Task 2: Remove Ollama from LLMProviderStore

**Files:**
- Modify: `Memgram/AI/LLMProviderStore.swift`

- [ ] **Step 1: Remove ollamaModel property**

Remove the `@Published var ollamaModel` property and its `didSet`:
```swift
// remove these lines:
@Published var ollamaModel: String {
    didSet { UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel") }
}
```

- [ ] **Step 2: Remove ollamaModel from init**

Remove from `private init()`:
```swift
// remove:
ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2"
```

- [ ] **Step 3: Remove .ollama case from providerFor and update .qwen fallback**

In `providerFor(_:)`, remove the `.ollama` case:
```swift
// remove:
case .ollama:
    return OllamaProvider(model: ollamaModel)
```

Update the `.qwen` fallback for non-MLXLLM / older macOS to use CustomServerProvider (Ollama's OpenAI-compatible endpoint) instead of OllamaProvider:
```swift
case .qwen:
    #if canImport(MLXLLM)
    if #available(macOS 14, *) { return QwenLocalProvider.shared }
    else {
        return CustomServerProvider(
            baseURL: customServerURL,
            apiKey: KeychainHelper.load(key: "customServerKey") ?? "",
            modelName: customServerModel
        )
    }
    #else
    return CustomServerProvider(
        baseURL: customServerURL,
        apiKey: KeychainHelper.load(key: "customServerKey") ?? "",
        modelName: customServerModel
    )
    #endif
```

- [ ] **Step 4: Remove fetchOllamaModels()**

Remove the entire method:
```swift
// remove:
func fetchOllamaModels() async -> [String] {
    await OllamaProvider(model: ollamaModel).listModels()
}
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Memgram/AI/LLMProviderStore.swift
git commit -m "feat: remove Ollama provider from LLMProviderStore"
```

---

## Task 3: Add cancelDownload() to QwenLocalProvider

**Files:**
- Modify: `Memgram/AI/QwenLocalProvider.swift`

- [ ] **Step 1: Add loadTask property**

Inside the `QwenLocalProvider` class, after `private var modelContainer: ModelContainer?`, add:
```swift
private var loadTask: Task<Void, Error>?
```

- [ ] **Step 2: Refactor loadModel() to use a tracked Task**

Replace the existing `loadModel()` body with a version that stores the task and handles cancellation:

```swift
func loadModel() async throws {
    guard !isLoaded else { return }
    loadError = nil
    downloadProgress = 0

    let task = Task<Void, Error> {
        let config = ModelConfiguration(id: Self.modelID, defaultPrompt: "Hello")
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: config
        ) { [weak self] progress in
            let frac = progress.fractionCompleted
            Task { @MainActor [weak self] in
                self?.downloadProgress = frac
            }
            if Int(frac * 100) % 10 == 0 {
                print("[QwenLocal] Download progress: \(Int(frac * 100))%")
            }
        }
        await MainActor.run { [weak self] in
            self?.modelContainer = container
            self?.isLoaded = true
            self?.downloadProgress = 1.0
            self?.loadTask = nil
            print("[QwenLocal] ✓ Model loaded successfully")
        }
    }
    loadTask = task
    do {
        try await task.value
    } catch is CancellationError {
        print("[QwenLocal] Download cancelled")
        downloadProgress = 0
        loadTask = nil
        // Don't set loadError — cancellation is intentional
    } catch {
        print("[QwenLocal] ✗ Model load failed: \(error)")
        loadError = error.localizedDescription
        loadTask = nil
        throw error
    }
}
```

- [ ] **Step 3: Add cancelDownload()**

After `preload()`, add:
```swift
func cancelDownload() {
    print("[QwenLocal] cancelDownload() called — cancelling in-flight load task")
    loadTask?.cancel()
    loadTask = nil
    downloadProgress = 0
    loadError = nil
    // isLoaded intentionally not reset — if model was already loaded, keep it
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Memgram/AI/QwenLocalProvider.swift
git commit -m "feat: add cancelDownload() to QwenLocalProvider with tracked Task"
```

---

## Task 4: Auto-Cancel Qwen When Switching Engine

**Files:**
- Modify: `Memgram/AI/LLMProviderStore.swift`

- [ ] **Step 1: Add auto-cancel to selectedBackend didSet**

Change:
```swift
@Published var selectedBackend: LLMBackend {
    didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: "llmBackend") }
}
```
to:
```swift
@Published var selectedBackend: LLMBackend {
    didSet {
        UserDefaults.standard.set(selectedBackend.rawValue, forKey: "llmBackend")
        // Cancel any in-progress Qwen download when user switches away
        if oldValue == .qwen && selectedBackend != .qwen {
            #if canImport(MLXLLM)
            if #available(macOS 14, *) {
                QwenLocalProvider.shared.cancelDownload()
            }
            #endif
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Memgram/AI/LLMProviderStore.swift
git commit -m "feat: auto-cancel Qwen download when user switches AI engine"
```

---

## Task 5: Track Whisper Download State in WhisperModelManager

**Files:**
- Modify: `Memgram/Transcription/WhisperModelManager.swift`
- Modify: `Memgram/Transcription/TranscriptionEngine.swift`

- [ ] **Step 1: Add isWhisperDownloading to WhisperModelManager**

In `WhisperModelManager`, add after the existing `@Published var preferMultilingual`:
```swift
/// True while WhisperKit is downloading or loading the model for the first time.
@Published var isWhisperDownloading: Bool = false
```

- [ ] **Step 2: Hook WhisperKit modelStateCallback in TranscriptionEngine**

Read `TranscriptionEngine.swift`. Find the `WhisperKit(model: modelName, ...)` init call (around line 50). Replace it with a version that sets `isWhisperDownloading` before and tracks state via the callback:

```swift
// Before creating WhisperKit, mark as downloading
await MainActor.run {
    WhisperModelManager.shared.isWhisperDownloading = true
}

let wk = try await WhisperKit(
    model: modelName,
    verbose: false,
    logLevel: .none,
    modelStateCallback: { _, newState in
        let busy = newState == .downloading || newState == .loading || newState == .prewarming
        Task { @MainActor in
            WhisperModelManager.shared.isWhisperDownloading = busy
        }
    }
)
self.whisperKit = wk

// Ensure flag is cleared after init regardless of callback timing
await MainActor.run {
    WhisperModelManager.shared.isWhisperDownloading = false
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Transcription/WhisperModelManager.swift Memgram/Transcription/TranscriptionEngine.swift
git commit -m "feat: expose isWhisperDownloading on WhisperModelManager via WhisperKit modelStateCallback"
```

---

## Task 6: Add Download Progress Cards to PopoverView

**Files:**
- Modify: `Memgram/UI/MenuBar/PopoverView.swift`

- [ ] **Step 1: Add WhisperModelManager observation**

In `PopoverView`, after the existing `@ObservedObject private var session = RecordingSession.shared` line, add:
```swift
@ObservedObject private var whisperManager = WhisperModelManager.shared
```

- [ ] **Step 2: Add downloadCards view builder**

Add this private computed property to `PopoverView`, alongside the existing `upcomingEventCard`:

```swift
@ViewBuilder
private var downloadCards: some View {
    // Whisper card — shown during first-run model download/load
    if whisperManager.isWhisperDownloading {
        downloadProgressCard(
            icon: "arrow.down.circle",
            iconColor: .blue,
            title: "Setting up Whisper",
            subtitle: "\(whisperManager.selectedModel.sizeMB) MB · first run only",
            progress: nil  // indeterminate — WhisperKit doesn't expose per-step progress
        )
    }

    // Qwen card — shown during model download, with retry on error
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
```

- [ ] **Step 3: Add QwenDownloadCard helper view**

Add this view near the bottom of `PopoverView.swift` (outside the main struct):

```swift
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
                    Text(hasError ? "Qwen download failed" : "Downloading Qwen 3.5 9B")
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
```

- [ ] **Step 4: Insert downloadCards into the idle section**

Find the idle section in the popover body (the `else` branch that shows `upcomingEventCard` and `statusSection`). Insert `downloadCards` at the top of that branch, before `upcomingEventCard`:

```swift
} else {
    downloadCards          // ← add this line
    upcomingEventCard
    statusSection
    // ... existing content
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Memgram/UI/MenuBar/PopoverView.swift
git commit -m "feat: show Qwen and Whisper download progress cards in popover idle area"
```

---

## Task 7: Redesign AISettingsTab as Single-Page Form

**Files:**
- Modify: `Memgram/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Replace AISettingsTab body with Form layout**

Find the `AISettingsTab` struct (currently `HStack(spacing: 0) { providerSidebar ... }`). Replace its entire `body` and all private members (`providerSidebar`, `configPanel`, `testBar`, `ProviderRow`) with:

```swift
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
```

Delete the now-unused `private struct ProviderRow` entirely.

Also remove `OllamaConfigView` struct entirely.

- [ ] **Step 2: Shrink window size**

In `SettingsView.body`, change:
```swift
.frame(width: 620, height: 500)
```
to:
```swift
.frame(width: 520, height: 440)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/UI/Settings/SettingsView.swift
git commit -m "feat: redesign AI settings as single-page form with popup engine picker, remove Ollama UI"
```

---

## Task 8: Final Build Verification and Push

- [ ] **Step 1: Full Release build**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Release build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Push**

```bash
git push
```
