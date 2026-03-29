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

**⚠️ WhisperKit fork:** Using `ekabanov/WhisperKit` (fork of `argmaxinc/WhisperKit`) pinned to commit `69c0a9d`. The only change from upstream is `swift-transformers` constraint relaxed from `< 1.2.0` to `>= 1.2.0` in `Package.swift`. This unblocks MLXSwiftLM `branch: main`. If upstream WhisperKit ever ships a release with `swift-transformers >= 1.2.0`, revert to `argmaxinc/WhisperKit` with `from: "0.x.0"`.

## Calendar Integration

`Memgram/Calendar/` contains three files with no dependencies on each other beyond `CalendarContext`:

- **`CalendarContext.swift`** — `Codable/Equatable` snapshot of an `EKEvent` (title, notes, attendees, organizer, start/end). Stored as JSON in `meetings.calendar_context`. `promptBlock()` formats it for LLM injection. Static `scheduledDateFormatter` to avoid repeated allocations.
- **`CalendarManager.swift`** — `@MainActor ObservableObject` singleton. Wraps `EKEventStore`. Manages auth, upcoming event polling (60s timer + `EKEventStoreChanged`), calendar list, and `selectedCalendarIds` (UserDefaults, empty = all). `refreshUpcomingEvent()` excludes events whose `startDate` is >10 minutes in the past.
- **`CalendarNotificationService.swift`** — `UNUserNotification` scheduling. Category `MEETING_START` with action `START_RECORDING`. `scheduleNotification(for:)` fires 60s before event. `cancelAll()` scoped to `"meeting-"` prefix only.

**Icon states:** `RecordingState` has a `.upcoming` case — purple `calendar.badge.clock` with a slow 2s pulse. Driven by `CalendarManager.$upcomingEvent` in `AppDelegate`. Reverts to `.idle` when `upcomingEvent` becomes nil (i.e. event started >10 min ago or was cancelled).

**Notification handler:** `AppDelegate` is `UNUserNotificationCenterDelegate`. `didReceive` looks up the event by `eventIdentifier` from `userInfo` first (`EKEventStore.event(withIdentifier:)`), falls back to `findEvent(around: Date(), toleranceMinutes: 30)`.

**Prompt injection:** `SummaryEngine.summarizeShort(transcript:calendarContext:provider:)` prepends a calendar metadata block before `Transcript:` when context is non-nil. Nil path is byte-for-byte identical to pre-calendar behavior.

**DB schema:** `meetings` table has two new nullable text columns (`calendar_event_id`, `calendar_context`) added by GRDB migration `"v3_calendar_fields"`.

**Pitfalls:**
- `EKParticipant` does not expose `email` reliably — store display names only.
- `EKAuthorizationStatus.fullAccess` (macOS 14+) is distinct from the deprecated `.authorized`. Always check for `.fullAccess`.
- `predicateForEvents(withStart:end:calendars:)` matches events that *overlap* the window, not just those that start within it — filter by `startDate > cutoff` explicitly.

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

## PDF Export

`PDFExporter` (`Memgram/Export/PDFExporter.swift`) exports a meeting summary as a PDF file.

- **Renderer:** Pure AppKit — `NSTextView` + `dataWithPDF(inside:)`. No WebKit.
- **Why not WKWebView:** Sandboxed apps lack `com.apple.runningboard.assertions.webkit`, so WKWebView cannot spawn its WebContent process. Using it causes a hung continuation (`SWIFT TASK CONTINUATION MISUSE: leaked its continuation`).
- **Entry point:** `PDFExporter.export(meeting:) async throws -> Data` — `@MainActor`, synchronous layout under the hood.
- **Markdown parsing:** Line-by-line — `##`/`###` headings, `**bold**` (regex + NSFontManager), `` `code` `` (monospaced + background), `- `/`* ` bullets. Inline span regex is applied after building the base `NSMutableAttributedString` (not on HTML-escaped text).
- **Output:** Single tall PDF page sized to content. Sufficient for sharing; PDF viewers handle tall pages correctly.
- **MeetingDetailView integration:** "Export PDF…" (NSSavePanel) and "Share…" (NSSharingServicePicker) in the `⋯` menu, disabled when `summary == nil`. `isExporting` state shows a `ProgressView` spinner in place of the `⋯` button.

## LLM Streaming

`LLMProvider` has a `stream(system:user:) -> AsyncThrowingStream<String, Error>` method alongside `complete()`.

- **Default implementation:** wraps `complete()` — yields the full response as a single chunk. Qwen uses this path.
- **SSE providers (Claude, OpenAI, Custom Server, Gemini):** use `URLSession.bytes(for:)` + `bytes.lines` to parse Server-Sent Events. Add `stream: true` to the request body. Parse `data:` prefixed JSON lines, skipping `[DONE]` sentinels.
- **Gemini SSE:** uses `streamGenerateContent?alt=sse` endpoint instead of `generateContent`.
- **SummaryEngine streaming:** `summarize()` builds an `onChunk: (String) -> Void` closure that strips `<think>` tags, suppresses updates while a `<think>` block is open (Qwen reasoning), and dispatches `streamingText[meetingId] = visible` to main actor. `summarizeShort` and `summarizeFinal` both use `provider.stream()` loops and call `onChunk` with the accumulated string after each token.
- **`streamingText: [String: String]`** — `@Published` on `SummaryEngine`. Set during generation, cleared by `defer` in `summarize()` (covers all exit paths including early returns and errors).
- **MeetingDetailView:** shows `streamingText[meetingId]` as live `Markdown` with a "Generating…" badge overlay while active; falls back to saved summary; skeleton while waiting for first tokens.
- **`<think>` suppression:** `onChunk` checks `hasPrefix("<think>") && !contains("</think>")` — no UI updates while the thinking block is still open, then content streams normally once `</think>` appears.
- **Qwen thinking disabled:** `ChatSession` is created with `additionalContext: ["enable_thinking": false]`, which is passed as a Jinja template variable and suppresses the think block entirely. The `<think>` filter in `stream()` remains as a safety net.

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
