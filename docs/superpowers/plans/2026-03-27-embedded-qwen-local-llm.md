# Embedded Qwen 3.5 Local LLM — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed Qwen 3.5 9B 4-bit as an in-process local LLM for meeting summaries, making it the default provider. The model auto-downloads from HuggingFace on first use.

**Architecture:** Use the NEW `ml-explore/mlx-swift-lm` package (separate from the old broken `mlx-swift-examples`). This package exports `MLXLLM` with a high-level `ChatSession` API, HuggingFace model download, and Metal GPU acceleration. If MLX path fails, fall back to `llama.swift` (GGUF format). The plan includes explicit verification spikes before committing to either path.

**Tech Stack:** `mlx-swift-lm` (primary), `llama.swift` (fallback), HuggingFace Hub, Metal GPU

**Risk:** Qwen 3.5 is a new model — its architecture support in mlx-swift-lm needs to be verified, not assumed. The plan includes explicit "does it compile / does it load / does it generate" checkpoints.

---

## File Map (final state, after verification)

| Action | Path |
|--------|------|
| Modify | `project.yml` — add mlx-swift-lm dependency |
| Create | `Memgram/AI/QwenLocalProvider.swift` — in-process inference via MLXLLM |
| Modify | `Memgram/AI/LLMProvider.swift` — add `.qwen` case back to LLMBackend |
| Modify | `Memgram/AI/LLMProviderStore.swift` — wire .qwen, set as default |
| Modify | `Memgram/UI/Settings/SettingsView.swift` — Qwen config with download status |

---

## Task 1: Spike — Verify mlx-swift-lm compiles and resolves

**Goal:** Prove the package resolves, compiles, and `MLXLLM` can be imported. No app code yet.

**Files:**
- Modify: `project.yml` (temporary, may revert)

- [ ] **Step 1: Add mlx-swift-lm to project.yml**

Read `project.yml`. In the `packages:` section, add:

```yaml
  MLXSwiftLM:
    url: https://github.com/ml-explore/mlx-swift-lm
    branch: main
```

In `dependencies:` under the Memgram target, add:

```yaml
      - package: MLXSwiftLM
        product: MLXLLM
```

**Note:** Use `branch: main` not `from:` — we need the latest code for Qwen3.5 support. Pin to a tag later once we confirm it works.

- [ ] **Step 2: Regenerate and resolve**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug -resolvePackageDependencies 2>&1 | tail -10
```

**Check:** Does it resolve without errors? Look for the `mlx-swift-lm` checkout. If resolution fails (repo moved, renamed, etc.), try alternative URLs:
- `https://github.com/ml-explore/mlx-swift-lm.git`
- Check the ml-explore GitHub org for the actual repo name

- [ ] **Step 3: Build with minimal import test**

Create a temporary test file `Memgram/AI/MLXImportTest.swift`:

```swift
#if canImport(MLXLLM)
import MLXLLM
// If this compiles, the package is working
let _mlxAvailable = true
#else
let _mlxAvailable = false
#endif
```

Build:
```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -15
```

**Decision gate:**
- BUILD SUCCEEDED + `canImport(MLXLLM)` is true → proceed to Task 2
- BUILD FAILED with compile errors in mlx-swift-lm → check if errors are fixable (version pin, API changes). If not → jump to Task 2-ALT (llama.swift fallback)
- Package not found → verify repo URL exists, try alternatives

- [ ] **Step 4: Delete test file, commit if successful**

```bash
rm Memgram/AI/MLXImportTest.swift
git add project.yml && git commit -m "spike: add mlx-swift-lm dependency (MLXLLM compiles)"
```

If it FAILED, revert:
```bash
git checkout -- project.yml
```

---

## Task 2: Spike — Verify Qwen 3.5 loads and generates

**Goal:** Prove the model can be downloaded, loaded, and produces coherent text. This is the critical risk point.

**Files:**
- Create: `Memgram/AI/QwenLocalProvider.swift` (initial version)

- [ ] **Step 1: Discover the actual mlx-swift-lm API**

The research suggests this API but it MUST be verified:

```bash
find ~/Library/Developer/Xcode/DerivedData/Memgram-*/SourcePackages/checkouts/mlx-swift-lm -name "*.swift" | xargs grep -l "ChatSession\|loadModel\|ModelContainer\|loadModelContainer" 2>/dev/null | head -10
```

Read the key files to confirm:
- How to load a model (factory method, configuration)
- How to run chat inference (ChatSession or generate)
- What the progress callback looks like for model download
- Whether `Qwen3` or `Qwen3_5` architecture is registered

Also check if Qwen3.5 architecture is registered:
```bash
find ~/Library/Developer/Xcode/DerivedData/Memgram-*/SourcePackages/checkouts/mlx-swift-lm -name "*.swift" | xargs grep -i "qwen3\|qwen3_5\|Qwen3_5\|qwen3\.5" 2>/dev/null | head -20
```

- [ ] **Step 2: Create QwenLocalProvider with a test method**

```swift
// Memgram/AI/QwenLocalProvider.swift
import Foundation
#if canImport(MLXLLM)
import MLXLLM

@available(macOS 14.0, *)
@MainActor
final class QwenLocalProvider: ObservableObject, LLMProvider {
    static let shared = QwenLocalProvider()
    static let modelID = "mlx-community/Qwen3.5-9B-MLX-4bit"

    let name = "Qwen 3.5 9B (local)"

    @Published var downloadProgress: Double = 0
    @Published var isLoaded = false
    @Published var loadError: String?

    private var modelContainer: /* actual type from API discovery */
    // ... implementation based on discovered API
}
#endif
```

**The exact implementation depends on Step 1 findings.** The implementer MUST read the mlx-swift-lm source first, then write code that matches the actual API.

- [ ] **Step 3: Build and run the smoke test**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -15
```

If build succeeds, run the app and call the test from Settings or a debug button:
- Does the model download from HuggingFace? (watch Console for progress)
- Does it load without "Unsupported model type" errors?
- Does `complete(system:user:)` return coherent text?

**Decision gate:**
- Model downloads + loads + generates text → proceed to Task 3
- "Unsupported model type" error → Qwen3.5 architecture not in mlx-swift-lm. Try:
  - `mlx-community/Qwen3-8B-4bit` (Qwen3, not 3.5) as an alternative
  - Check if there's a newer branch/tag of mlx-swift-lm
  - If no Qwen works → jump to Task 2-ALT
- Download fails → check model ID exists on HuggingFace. Try alternatives:
  - `mlx-community/Qwen3-8B-Instruct-4bit`
  - `mlx-community/Qwen3-4B-4bit` (smaller, for testing)

- [ ] **Step 4: Commit if successful**

```bash
git add Memgram/AI/QwenLocalProvider.swift
git commit -m "spike: QwenLocalProvider loads and generates via mlx-swift-lm"
```

---

## Task 2-ALT: Fallback — llama.swift with GGUF (only if Task 2 fails)

**Skip this task entirely if Task 2 succeeds.**

**Goal:** If mlx-swift-lm doesn't support Qwen3.5, use llama.cpp via `llama.swift` with GGUF format instead.

**Files:**
- Modify: `project.yml` — swap mlx-swift-lm for llama.swift
- Create: `Memgram/AI/QwenLocalProvider.swift` — GGUF-based version

- [ ] **Step 1: Replace dependency**

Remove mlx-swift-lm from project.yml. Add:

```yaml
  LlamaSwift:
    url: https://github.com/siuying/llama.swift
    branch: main
```

Or alternatively Stanford BDHG:
```yaml
  LlamaCpp:
    url: https://github.com/StanfordBDHG/llama.cpp
    branch: main
```

- [ ] **Step 2: Resolve and verify build**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug -resolvePackageDependencies 2>&1 | tail -5
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head -10
```

- [ ] **Step 3: Implement QwenLocalProvider with llama.swift API**

The implementation depends on which package resolves. Use a GGUF model:
- Model ID: `unsloth/Qwen3.5-9B-GGUF` or similar from HuggingFace
- Download the Q4_K_M quantization (~5GB)
- Load via llama.swift's API

- [ ] **Step 4: Verify generation works, commit**

Same smoke test as Task 2 Step 3.

---

## Task 3: Wire QwenLocalProvider into the app

**Prerequisite:** Task 2 (or 2-ALT) succeeded — QwenLocalProvider compiles, loads, and generates.

**Files:**
- Modify: `Memgram/AI/LLMProvider.swift`
- Modify: `Memgram/AI/LLMProviderStore.swift`

- [ ] **Step 1: Add `.qwen` back to LLMBackend**

In `LLMProvider.swift`, add the `.qwen` case:

```swift
enum LLMBackend: String, CaseIterable, Identifiable {
    case qwen    = "qwen"     // Local Qwen via MLX
    case ollama  = "ollama"
    case custom  = "custom"
    case claude  = "claude"
    case openai  = "openai"
    case gemini  = "gemini"

    var displayName: String {
        switch self {
        case .qwen:   return "Qwen 3.5 9B (Local)"
        // ... existing cases unchanged
        }
    }

    var category: LLMBackendCategory {
        switch self {
        case .qwen, .ollama:            return .freeLocal
        // ... existing cases unchanged
        }
    }

    var badge: String {
        switch self {
        case .qwen, .ollama:            return "Free"
        // ... existing cases unchanged
        }
    }
}
```

- [ ] **Step 2: Wire `.qwen` in LLMProviderStore**

Default to `.qwen`. In `currentProvider`:

```swift
case .qwen:
    #if canImport(MLXLLM)
    if #available(macOS 14, *) { provider = QwenLocalProvider.shared }
    else                        { provider = OllamaProvider(model: "qwen3:8b") }
    #else
    provider = OllamaProvider(model: "qwen3:8b")  // fallback if MLX unavailable
    #endif
```

Change default: `selectedBackend = LLMBackend(rawValue: saved) ?? .qwen`

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

- [ ] **Step 4: Commit**

```bash
git add Memgram/AI/LLMProvider.swift Memgram/AI/LLMProviderStore.swift
git commit -m "feat(ai): add .qwen backend as default, wired to QwenLocalProvider"
```

---

## Task 4: Settings UI — Qwen config with download status

**Files:**
- Modify: `Memgram/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Add QwenConfigView**

Add a view for the Qwen settings panel that shows:
- Model name and description
- Download progress (reading from `QwenLocalProvider.shared.downloadProgress`)
- "Download Model" button that calls `QwenLocalProvider.shared.preload()`
- Error state if loading fails
- "Model loaded" success state

```swift
private struct QwenConfigView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Qwen 3.5 9B (Local)", systemImage: "cpu")
                .font(.headline)
            Text("Runs entirely on your Mac using Apple MLX. Downloads ~4.5 GB on first use. Requires Apple Silicon.")
                .font(.body).foregroundColor(.secondary)
            #if canImport(MLXLLM)
            QwenDownloadStatusView()
            #else
            Label("MLX not available", systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
            #endif
        }
    }
}

#if canImport(MLXLLM)
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
```

- [ ] **Step 2: Add `.qwen` case to the config switch**

In `AISettingsTab.configPanel`, add:
```swift
case .qwen:   QwenConfigView()
```

- [ ] **Step 3: Build and verify end-to-end**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Run the app:
1. Open Settings → AI → Qwen should be listed in sidebar under "Free Local"
2. Click "Download Model" → progress bar shows
3. After download, model loads
4. Record a meeting → summary uses Qwen locally

- [ ] **Step 4: Commit and push**

```bash
git add Memgram/UI/Settings/SettingsView.swift
git commit -m "feat(ui): add Qwen download status in Settings; Qwen is now the default LLM"
git push
```

---

## Spec Coverage

| Requirement | Task |
|-------------|------|
| Embed Qwen 3.5 9B 4-bit in the app | Tasks 1–2 |
| Auto-download model from HuggingFace | Task 2 (MLXLLM handles via Hub) |
| Run locally on Apple Silicon | Task 2 (Metal GPU via MLX) |
| Default provider | Task 3 (`.qwen` default in LLMProviderStore) |
| Download progress UI | Task 4 (QwenDownloadStatusView) |
| Fallback if MLX fails | Task 2-ALT (llama.swift with GGUF) |
| Trial and error approach | Tasks 1–2 have explicit decision gates |

## Key Decision Points

1. **After Task 1:** Does mlx-swift-lm compile? If not → investigate or fallback
2. **After Task 2 Step 3:** Does Qwen3.5 load? If "Unsupported model type" → try Qwen3, or fallback to GGUF
3. **After Task 2-ALT:** Does llama.swift work with Qwen GGUF? If not → stay with Custom Server approach (known working)

At each gate, the implementer should report findings before proceeding.
