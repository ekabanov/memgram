# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build System

The project uses **xcodegen** to generate `Memgram.xcodeproj` from `project.yml`. Run this after changing `project.yml` or adding new Swift files:
```bash
xcodegen generate
```

Build from the command line:
```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build
```

There are no tests (`testTargets: []` in `project.yml`). There is no linter configured.

**Deployment target:** macOS 14.0 (raised from 13.0 due to MLXLLM and WhisperKit requirements).

## Architecture

Memgram is a macOS menu bar app (no dock icon, `LSUIElement: true`) that records meetings, transcribes locally via WhisperKit, generates AI summaries, and provides semantic search. All processing is offline — no audio leaves the device.

**Entry point:** `AppDelegate` (not SwiftUI `@main`). `MemgramApp.swift` is the `@main` entry but immediately delegates to `AppDelegate`. The status bar item, popover, and main window are all owned by `AppDelegate`. Settings are registered as a `Settings { SettingsView() }` scene — use `SettingsLink` (not `sendAction`) to open them.

**Data flow:**
```
MicrophoneCapture (AVAudioEngine tap, 16kHz mono Float32)
         ↓ bufferPublisher
    StereoMixer  ←  SystemAudioCaptureProvider.bufferPublisher
         ↓ chunkPublisher (stereo 30s AVAudioPCMBuffer, L=mic R=system)
  TranscriptionEngine (WhisperKit)
         ↓ segmentPublisher
  RecordingSession.segments → LiveTranscriptView + MeetingStore (GRDB)
         ↓ on finalization
  SummaryEngine + EmbeddingEngine (background Tasks)
```

**`RecordingSession.shared`** is the single coordinator (`@MainActor`). It owns all audio components and the transcription engine. `PopoverView` and `AppDelegate` observe it.

**System audio capture uses a two-path architecture:**
- `makeSystemAudioCapture()` (in `SystemAudioCaptureProvider.swift`) returns `CoreAudioTapCapture` on macOS 14.4+, `ScreenCaptureKitCapture` on 13.0–14.3.
- `CoreAudioTapCapture`: `AudioHardwareCreateProcessTap` → private aggregate device → IOProc. Teardown must happen in reverse order (IOProc → aggregate → tap) to avoid OSStatus `1852797029`.
- **`kAudioObjectSystemObject` is NOT a valid process object** for `CATapDescription(stereoMixdownOfProcesses:)`. Always use `PermissionsManager.audioProcessObjectIDs()` to get real running process IDs.

**`StereoMixer`** accumulates samples from both sources independently (protected by `NSLock`) and emits a chunk only when both accumulators reach 480,000 frames (30s × 16kHz).

**`TranscriptionEngine`** wraps WhisperKit. Chunks are serialized (one at a time). WhisperKit loads and compiles CoreML on first use — first chunk in a new session takes longer due to CoreML compilation caching.

**`WhisperModelManager.shared`** tracks selected model. WhisperKit downloads and caches models automatically via HuggingFace Hub. Model names use the `openai_whisper-*` naming convention (e.g. `openai_whisper-large-v3-v20240930_turbo_632MB`). No manual download logic needed.

## Package Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| GRDB | 6.x | SQLite (WAL, FTS5) |
| WhisperKit | 0.9+ | Transcription (Metal/ANE) |
| MLXSwiftLM | commit `4051621` | Qwen 3.5 in-process inference |

**⚠️ MLXSwiftLM pinning note:** Pinned to specific commit `405162196eb484eeaa4afcc7bd354f9b559a11d5` because:
- `main` branch bumped `swift-transformers` to 1.2.0, conflicting with WhisperKit's requirement of `< 1.2.0`
- Tagged versions (1.18.x) don't include `Qwen35.swift`
- When WhisperKit upgrades to support `swift-transformers >= 1.2.0`, update `project.yml` to use `branch: main` for MLXSwiftLM.

## LLM Backends

- **Qwen 3.5 9B (Local)** — in-process via MLXSwiftLM (`mlx-community/Qwen3.5-9B-MLX-4bit`), default
- **Ollama** — local Ollama daemon
- **Custom Server** — any OpenAI-compatible server (LM Studio, mlx_lm.server, vLLM)
- **Claude / OpenAI / Gemini** — cloud APIs, keys stored in Keychain only

`SummaryEngine` strips `<think>...</think>` tags before saving summaries (reasoning models).

## Database

SQLite via GRDB at `~/Library/Application Support/Memgram/memgram.db`, WAL mode, FTS5 on segments. Schema: meetings → segments → speakers → embeddings. Foreign keys enforced with `PRAGMA foreign_keys = ON` via `config.prepareDatabase`.

## Important Implementation Details

- **`SWIFT_STRICT_CONCURRENCY: minimal`** — concurrency warnings are suppressed.
- **Bundle ID:** `com.memgram.app` — must match entitlements.
- **`Notification.Name.meetingDidUpdate`** — posted by SummaryEngine/MeetingStore after data changes; `MeetingDetailView` and `MeetingListView` observe it to refresh.
- **`MeetingDetailView`** must have `.id(meetingId)` in `MainWindowView` to force recreation on selection change (prevents stale content when clicking quickly in the list).
- **Settings:** Always use `SettingsLink { ... }` as a View to open the Settings window. `NSApp.sendAction(Selector("showSettingsWindow:"))` is rejected by the system.
- **LLM selector in popover** uses `SettingsLink` wrapper (`llmSettingsButton`) for the same reason.
