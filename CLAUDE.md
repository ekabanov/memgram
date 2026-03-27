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

No test targets. No linter. **Deployment target: macOS 14.0.**

## Architecture

Memgram is a macOS menu bar app (`LSUIElement: true`) that records meetings, transcribes locally via WhisperKit, and generates AI summaries. All processing is offline.

**Entry point:** `AppDelegate` via `MemgramApp.swift` (`@main`). Status bar item, popover, and main window owned by `AppDelegate`. Settings registered as `Settings { SettingsView() }` — use `SettingsLink` (not `sendAction`) to open them.

**Data flow:**
```
MicrophoneCapture (AVAudioEngine, 16kHz mono)
         ↓ bufferPublisher
    StereoMixer  ←  SystemAudioCaptureProvider
         ↓ 30s stereo chunks (L=mic, R=system)
  TranscriptionEngine (WhisperKit, Metal/ANE)
         ↓ segmentPublisher (main thread)
  RecordingSession → segments[] + MeetingStore (Task.detached DB write)
         ↓ on finalization
  SummaryEngine (background) → MeetingStore.saveSummary → meetingDidUpdate notification
```

**System audio:** CoreAudioTapCapture on macOS 14.4+, ScreenCaptureKitCapture fallback. `kAudioObjectSystemObject` is NOT a valid process object for `CATapDescription` — always use `PermissionsManager.audioProcessObjectIDs()`.

**Transcription:** WhisperKit auto-downloads models. Model auto-selected by `WhisperModelManager.autoSelectedModel` based on RAM + `preferMultilingual` flag. Users only see English/Multilingual toggle — no model list.

**LLM backends:** Qwen (local MLX via `mlx-swift-lm`), Ollama, Custom Server, Claude, OpenAI, Gemini. `LLMProviderStore.currentProvider` delegates to `providerFor(selectedBackend)`. API keys in Keychain only.

**SummaryEngine:** `@MainActor ObservableObject`. `activeMeetingIds: Set<String>` tracks in-progress jobs — observed by UI for spinners. `summarize()` runs LLM off main (awaits provider), saves to DB, then calls `generateTitle()`. Title generation runs AFTER `activeMeetingIds.remove()` so progress clears immediately.

**MeetingDetailView:** Summary rendered via `swift-markdown-ui` (`Markdown(summary).markdownTheme(.gitHub)`). Tab bar: Summary (default) | Transcript. Local transcript search with `filteredSegments`. Delete/Copy in header `⋯` menu.

## Package Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| GRDB | 6.x | SQLite (WAL, FTS5, `PRAGMA foreign_keys = ON`) |
| WhisperKit | 0.9+ | Transcription (Metal decoder + ANE encoder) |
| MLXSwiftLM | commit `4051621` | Qwen local inference |
| MarkdownUI | 2.x | Markdown rendering in summary tab |

**⚠️ MLXSwiftLM pinning:** Pinned to commit `4051621` — `main` branch broke `swift-transformers` compat with WhisperKit. When WhisperKit supports `swift-transformers >= 1.2.0`, switch to `branch: main`.

## iCloud Sync

`CloudSyncEngine` (`Memgram/Sync/CloudSyncEngine.swift`) wraps `CKSyncEngine` (macOS 14+) for syncing meetings, segments, and speakers via CloudKit private database.

- **Container:** `iCloud.com.memgram.app`, custom zone `MemgramZone`
- **Record IDs:** `"{table}_{uuid}"` format (e.g. `meetings_ABC-123`)
- **Enqueue pattern:** Each `MeetingStore` write method calls `sync?.enqueueSave/enqueueDelete` after the GRDB write. No TransactionObserver.
- **System fields:** Stored as `ck_system_fields` blob column (NSKeyedArchiver-encoded CKRecord metadata). Used to send updates as modifications, not creates.
- **FK ordering:** Segments/speakers may arrive before their parent meeting from CloudKit. `applyRemoteRecord` creates placeholder meetings to satisfy FK constraints.
- **Initial upload:** On first launch (no sync state in UserDefaults), all existing records are enqueued for upload.
- **What does NOT sync:** `embeddings`, `segments_fts` (rebuilt by triggers), WhisperKit/LLM models.
- **State persistence:** `CKSyncEngine.State.Serialization` JSON-encoded in UserDefaults key `CKSyncEngineState`. Note: on this machine, UserDefaults writes to `~/Library/Preferences/com.memgram.app.plist` (not the sandboxed container path).

**Pitfalls:**
- Never use raw SQL with `Date.timeIntervalSinceReferenceDate` in GRDB — always use Codable `update(db)`/`insert(db)`.
- `PRAGMA foreign_keys = OFF` is silently ignored inside GRDB `db.write {}` transactions.
- xcodegen regenerates `.entitlements` from `project.yml` — all entitlements must be in `entitlements.properties`, not added via Xcode UI.

## Key Implementation Details

- **SWIFT_STRICT_CONCURRENCY: minimal** — cross-actor accesses compile without errors.
- **Bundle ID:** `com.memgram.app`
- **`appendSegment` in RecordingSession** uses `Task.detached(priority: .utility)` to avoid blocking main thread during recording.
- **`cleanExistingSummaries`** uses `Task.detached` so GRDB calls don't block main.
- **`Notification.Name.meetingDidUpdate`** — posted on main actor after DB changes; observed by `MeetingDetailView` and `MeetingListView`.
- **`MeetingDetailView`** must have `.id(meetingId)` in `MainWindowView` to force recreation on selection change.
- **Settings:** Use `SettingsLink { }` as a View wrapper — `sendAction(showSettingsWindow:)` is rejected.
- **GRDB `content` is a reserved SQL identifier** — local variables named `content` in DB-adjacent code cause type errors (rename to `pasteStr`, `transcriptStr`, etc.).
- **WhisperKit model names** use `openai_whisper-*` prefix with size suffix for large models (e.g. `openai_whisper-large-v3-v20240930_turbo_632MB`).
- **Transcription drain timeout:** 120s `asyncAfter` in `RecordingSession.stop()` ensures meetings are never permanently stuck as `.transcribing`.
- **AppDatabase corruption:** Renames corrupt DB file and starts fresh instead of `fatalError`.
