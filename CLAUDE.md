# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build System

The project uses **xcodegen** to generate `Memgram.xcodeproj` from `project.yml`. Run this after changing `project.yml`:
```bash
xcodegen generate
```

Build from the command line:
```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build
```

There are no tests (`testTargets: []` in `project.yml`). There is no linter configured.

## Architecture

Memgram is a macOS menu bar app (no dock icon, `LSUIElement: true`) that records meetings, transcribes locally via whisper.cpp, and will provide AI summaries. All processing is offline — no audio leaves the device.

**Entry point:** `AppDelegate` (not SwiftUI `@main`). `MemgramApp.swift` is the `@main` entry but immediately delegates to `AppDelegate`. The status bar item, popover, and main window are all owned by `AppDelegate`.

**Data flow:**
```
MicrophoneCapture (AVAudioEngine tap, 16kHz mono Float32)
         ↓ bufferPublisher
    StereoMixer  ←  SystemAudioCaptureProvider.bufferPublisher
         ↓ chunkPublisher (stereo 30s AVAudioPCMBuffer, L=mic R=system)
  TranscriptionEngine (SwiftWhisper)
         ↓ segmentPublisher
  RecordingSession.segments → LiveTranscriptView
```

**`RecordingSession.shared`** is the single coordinator. It owns all audio components and the transcription engine. `PopoverView` and `AppDelegate` observe it.

**System audio capture uses a two-path architecture:**
- `makeSystemAudioCapture()` (in `SystemAudioCaptureProvider.swift`) returns `CoreAudioTapCapture` on macOS 14.4+, `ScreenCaptureKitCapture` on 13.0–14.3.
- `CoreAudioTapCapture`: `AudioHardwareCreateProcessTap` → private aggregate device → IOProc. Teardown must happen in reverse order (IOProc → aggregate → tap) to avoid OSStatus `1852797029`.
- `ScreenCaptureKitCapture`: `SCStream` with `capturesAudio = true`, 2×2 video (required even though frames are discarded), must register both `.screen` and `.audio` outputs.

**`StereoMixer`** accumulates samples from both sources independently (protected by `NSLock`) and emits a chunk only when both accumulators reach 480,000 frames (30s × 16kHz). Level meters are polled at 10Hz via a Timer instead of dispatching per-buffer.

**`TranscriptionEngine`** wraps `SwiftWhisper.Whisper`. The `Whisper` instance is **not reentrant** — concurrent calls return `WhisperError.instanceBusy`. Chunks must be serialized.

**`WhisperModelManager.shared`** downloads GGML model files to `~/Library/Application Support/Memgram/models/`. The first-launch sheet is shown from `PopoverView.onAppear` if no model is ready.

## Key Known Issues (Session 3)

- `ModelDownloadView.closeSheet()` calls itself recursively (should call `dismiss()`).
- `TranscriptionEngine` dispatches each chunk as an independent `Task` without waiting for the previous transcription to finish, causing `instanceBusy` errors that silently drop all chunks after the first.

## Important Implementation Details

- **`SWIFT_STRICT_CONCURRENCY: minimal`** — concurrency warnings are suppressed. Many types cross actor boundaries unsafely.
- **Bundle ID:** `com.memgram.app` — must match entitlements.
- **Entitlements required at runtime:** `com.apple.security.screen-capture` (for `SCStream` and `CoreAudioTap`), `com.apple.security.device.audio-input` (mic).
- **`AudioConverter.resampleToMono16k`** (`Utilities/AudioConverter.swift`) converts any native format to 16kHz mono Float32 for both mic and system audio paths before they reach `StereoMixer`.
- **`WhisperModel.downloadURL`** fetches from `huggingface.co/ggerganov/whisper.cpp` — requires `com.apple.security.network.client` entitlement.
- SwiftWhisper `Segment.startTime`/`endTime` are in **milliseconds** (the library multiplies whisper's centisecond values by 10 internally). Divide by 1000.0 to get seconds.

## Session Build Plan

Sessions 1–7 build the app incrementally. See `memgram_claude_code_plan.md` for the full prompt for each session. Sessions 1–3 are implemented (Session 3 has bugs). Session 4 adds GRDB SQLite persistence (GRDB package is already in `project.yml`).
