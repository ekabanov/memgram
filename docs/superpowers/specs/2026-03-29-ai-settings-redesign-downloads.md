# AI Settings Redesign + Download Improvements Design

## Goal

Two coordinated changes:
1. Replace the sidebar+panel AI settings layout with a single-page form (popup picker + config below). Remove Ollama.
2. Show download progress for Qwen and Whisper in the main popover. Make Qwen downloads more robust. Auto-cancel Qwen download when user switches engine.

---

## Section 1: AI Settings Page Redesign

### Layout

Replace `AISettingsTab`'s sidebar+panel with a single `Form` (.grouped style), three sections:

**Section "AI Engine"**
- `Picker("AI Engine", selection: $store.selectedBackend)` with `.menu` pickerStyle
- Qwen is the default (existing UserDefaults default, unchanged)

**Section titled with the engine name**
- Content switches on `store.selectedBackend`: Qwen config, Custom Server config, Claude key, OpenAI key, Gemini key
- Same config sub-views as today (QwenConfigView, CustomServerConfigView, APIKeyConfigView)

**Section "Test"**
- "Test Connection" button + status text as a Form row

### Window size

Shrink from 620×500 to 520×440 (sidebar gone, more compact).

### Ollama removal

- Delete `OllamaConfigView`
- Remove `.ollama` case from `LLMBackend` enum
- Remove Ollama from `LLMBackendCategory` and `LLMProviderStore`
- Update any switch statements that handle `.ollama`
- `CustomServerConfigView` description already covers Ollama ("LM Studio, vLLM, local Ollama, etc.") — no copy change needed

---

## Section 2: Download Progress + Robustness

### Qwen robustness

- Increase `timeoutIntervalForResource` on the URLSession used by MLX model download to 3600s
- Add `cancelDownload()` to `QwenLocalProvider` — cancels any in-flight download task and resets state
- `LLMProviderStore.selectedBackend` didSet: when switching away from `.qwen`, call `QwenLocalProvider.shared.cancelDownload()`
- Show "Retry" button (not just error text) in both `QwenDownloadStatusView` (settings) and the popover card on `loadError`

### Whisper progress forwarding

- `WhisperModelManager` gains `@Published var whisperDownloadProgress: Double = 0` and `@Published var isWhisperDownloading: Bool = false`
- `TranscriptionEngine.loadModel()` passes a progress handler to WhisperKit's `loadModels()` that updates these published properties on `WhisperModelManager.shared`

### Download progress card in PopoverView

Shown in the idle area (same slot as upcoming event card) when either download is active. Priority: Whisper card shown above Qwen card if both are active.

**Whisper card** (shown when `whisperModelManager.isWhisperDownloading`):
- Icon: `arrow.down.circle` in blue
- Title: "Downloading Whisper model"
- Subtitle: model size (e.g. "632 MB")
- Progress bar + percentage

**Qwen card** (shown when `qwenProvider.downloadProgress > 0 && qwenProvider.downloadProgress < 1`):
- Icon: `arrow.down.circle` in purple
- Title: "Downloading Qwen 3.5 9B"
- Subtitle: "~4.5 GB · runs locally"
- Progress bar + percentage
- "Retry" button if `qwenProvider.loadError != nil`

No cancel buttons. Switching away from Qwen in settings auto-cancels.

### What is NOT in scope

- Whisper download cancellation
- Download resumption (resume from partial file)
- Background download (app must stay open)
