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

**Test target: MemgramTests** (macOS 14.0). Run with:
```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```
No linter. **Deployment target: macOS 14.0.**

## Architecture

Memgram is a macOS menu bar app (`LSUIElement: true`) that records meetings, transcribes locally via WhisperKit or Parakeet, and generates AI summaries. All processing is offline.

**Entry point:** `AppDelegate` via `MemgramApp.swift` (`@main`). Status bar item, popover, and main window owned by `AppDelegate`. Settings registered as `Settings { SettingsView() }` — use `SettingsLink` (not `sendAction`) to open them.

**Data flow:**
```
MicrophoneCapture (AVAudioEngine, 16kHz mono)
         ↓ bufferPublisher
    StereoMixer  ←  SystemAudioCaptureProvider
         ↓ 10s stereo chunks (L=mic, R=system)
  AudioChannelUtils.selectDominantChannel()
         ↓ dominant channel mono audio
  TranscriptionEngine (Parakeet/WhisperKit, ANE/Metal)
         ↓ segmentPublisher (main thread)
  RecordingSession → segments[] + MeetingStore (Task.detached DB write)
         ↓ on finalization
  SummaryEngine (background) → MeetingStore.saveSummary → meetingDidUpdate notification
```

**System audio:** CoreAudioTapCapture on macOS 14.4+, ScreenCaptureKitCapture fallback. `kAudioObjectSystemObject` is NOT a valid process object for `CATapDescription` — always use `PermissionsManager.audioProcessObjectIDs()`.

**Transcription:** Backend selectable in **Settings → Recording**. Default is Whisper Large v3 Turbo on Macs with ≥ 12 GB RAM, Parakeet (ANE) below that. WhisperKit auto-downloads models; model auto-selected by `WhisperModelManager.autoSelectedModel` based on RAM + `preferMultilingual` flag. Users only see English/Multilingual toggle — no model list. `TranscriptionBackendManager` tracks backend preference and Parakeet loading state.

**LLM backends:** Qwen (local MLX via `mlx-swift-lm`), Custom Server (OpenAI-compatible — covers Ollama/LM Studio/vLLM), Claude, OpenAI, Gemini. `LLMProviderStore.currentProvider` delegates to `providerFor(selectedBackend)`. API keys in Keychain only. All backends stream tokens via `provider.stream()` — cloud providers use SSE, Qwen uses `ChatSession.streamResponse()`.

**Qwen memory lifecycle:** `QwenLocalProvider.preload()` calls `loadModel()` then immediately `unload()` — this downloads and caches model files on disk, momentarily loads weights into memory to verify the model, then frees them. The download progress is reported through the standard `LLMModelFactory` callback so the popover shows a real byte-level progress bar. On `summarize()`, Qwen loads weights on demand; after the summary completes `SummaryEngine` calls `provider.unload()` which calls `MLX.Memory.clearCache()` to return GPU buffers to the OS. This keeps Qwen's peak footprint off RAM except during active use. Model tiers: Qwen 3.5 4B (< 16 GB RAM), Qwen 3.5 9B (16–47 GB), Qwen 3.6 35B-A3B MoE (≥ 48 GB, ~20 GB weights, 3B active). Qwen 3.6 ships no small models, so the lower tiers stay on 3.5.

**SummaryEngine:** `@MainActor ObservableObject`. `activeMeetingIds: Set<String>` tracks in-progress jobs — observed by UI for spinners. `summarize()` runs LLM off main (awaits provider), saves to DB, then calls `generateTitle()`. Title generation runs AFTER `activeMeetingIds.remove()` so progress clears immediately.

**MeetingDetailView:** Summary rendered via `swift-markdown-ui` (`Markdown(summary).markdownTheme(.gitHub)`). Tab bar: Summary (default) | Transcript. Local transcript search with `filteredSegments`. Delete/Copy in header `⋯` menu.

## Transcription Backends

`TranscriberProtocol` abstracts over two backends selectable in Settings → Recording:

- **`WhisperTranscriber`** — WhisperKit with Metal decoder + ANE encoder. Default on ≥ 12 GB RAM; supports multilingual. Auto-downloads model on first use.
- **`ParakeetTranscriber`** — FluidAudio ANE-based model. Default on < 12 GB RAM. No model download required; model is bundled or cached via FluidAudio. Lower latency than Whisper on Apple Silicon.

**`AudioChannelUtils.selectDominantChannel()`** — before feeding audio to the transcription backend, picks the louder of mic (L) and system (R) channels. Prevents transcription of both channels when only one has speech, which would double-transcribe echo.

**`TranscriptionBackendManager`** — `@MainActor ObservableObject`. Persists backend choice in UserDefaults. Tracks loading state for Parakeet (shown in Settings → Recording). Instantiates the active `TranscriberProtocol` implementation on demand.

## Speaker Diarization (REMOVED 2026-04-09)

Speaker diarization + voice enrollment were fully implemented (dual-Sortformer `SpeakerDiarizer`, `SpeakerEnrollmentStore`, `enrollVoice` onboarding, `normaliseSpeakerLabels()` in `SummaryEngine`) and then **deliberately removed** — the `Room 1`/`Remote 1` labels and enrollment-based name resolution confused the LLM more than they helped. See commits `91efd0e` (disabled by default), `c8fa635` (stripped from LLM input), `fe18f1c` (files deleted). **Do not re-implement without an explicit request.**

Remnants kept for backwards compatibility — do not remove:
- `speaker` column in the `segments` table (no longer displayed or used); transcribers still tag segments `You`/`Remote` by channel.

The `MeetingStatus.diarizing` enum case was fully retired: migration `"v5_remove_diarizing"` maps legacy rows to `interrupted`, and `MeetingStatus` decodes unknown raw values (e.g. `"diarizing"` synced from old app builds) as `.interrupted` via tolerant `init(from:)`/`fromDatabaseValue` fallbacks — never let an unknown status value throw, a failing decode is indistinguishable from DB corruption.

## Package Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| GRDB | 6.x | SQLite (WAL, FTS5, `PRAGMA foreign_keys = ON`) |
| WhisperKit | 0.9+ | Transcription (Metal decoder + ANE encoder) |
| FluidAudio | main | Parakeet transcription (ANE) |
| MLXSwiftLM | branch `main` | Qwen local inference |
| MarkdownUI | 2.x | Markdown rendering in summary tab |

**⚠️ WhisperKit fork:** Using `ekabanov/WhisperKit` (fork of `argmaxinc/WhisperKit`) pinned to commit `69c0a9d`. The only change from upstream is `swift-transformers` constraint relaxed from `< 1.2.0` to `>= 1.2.0` in `Package.swift`. This unblocks MLXSwiftLM `branch: main`. If upstream WhisperKit ever ships a release with `swift-transformers >= 1.2.0`, revert to `argmaxinc/WhisperKit` with `from: "0.x.0"`.

## Calendar Integration

`Memgram/Calendar/` contains three files with no dependencies on each other beyond `CalendarContext`:

- **`CalendarContext.swift`** — `Codable/Equatable` snapshot of an `EKEvent` (title, notes, attendees, organizer, start/end). Stored as JSON in `meetings.calendar_context`. `promptBlock()` formats it for LLM injection — **title, schedule, and notes only**; attendees/organizer are stored but deliberately excluded from the prompt (removed in `c8fa635`, they degraded summaries). Static `scheduledDateFormatter` to avoid repeated allocations.
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

`CloudSyncEngine` (`Memgram/Sync/CloudSyncEngine.swift`) syncs meetings, segments, and speakers via CloudKit private database. Uses `SyncTransport` protocol for testability — production uses `CKSyncTransport` (wraps real `CKSyncEngine`); tests use `FakeSyncTransport`.

- **Container:** `iCloud.com.memgram.app`, custom zone `MemgramZone`
- **Record IDs:** `"{table}_{uuid}"` format (e.g. `meetings_ABC-123`)
- **`SyncTransport` protocol** (`Memgram/Sync/SyncTransport.swift`) — abstraction over `CKSyncEngine`. Production: `CKSyncTransport` created in `start()`. Tests: `FakeSyncTransport` injected via `init(db:transport:)`.
- **`SyncStatus` enum** — `pendingUpload`, `placeholder`, `synced`, `failed`. Stored as `sync_status` text column in `meetings` table. Set by `enqueueSave` (→ `pendingUpload`), `didSend` success (→ `synced`), `didSend` failure (→ `failed`), `applyRemoteRecord` (→ `synced`).
- **`MeetingStatus` enum** — `recording`, `transcribing`, `done`, `interrupted`, `error`. `interrupted` set by crash recovery for stuck meetings; unknown/legacy raw values (e.g. `"diarizing"`) decode as `.interrupted`.
- **Enqueue pattern:** Each `MeetingStore` write method calls `sync?.enqueueSave/enqueueDelete` after the GRDB write. No TransactionObserver.
- **System fields:** Stored as `ck_system_fields` blob column (NSKeyedArchiver-encoded CKRecord metadata). Used to send updates as modifications, not creates.
- **FK ordering:** Segments/speakers may arrive before their parent meeting from CloudKit. `applyRemoteRecord` creates placeholder meetings (`syncStatus = .placeholder`, `title = "Syncing…"`) to satisfy FK constraints.
- **Initial upload:** On first launch (no sync state in UserDefaults), all existing records are enqueued. On subsequent launches, orphaned records (`sync_status = pending_upload`) are re-enqueued.
- **What does NOT sync:** `embeddings`, `segments_fts` (rebuilt by triggers), WhisperKit/LLM models.
- **State persistence:** `CKSyncEngine.State.Serialization` JSON-encoded in UserDefaults key `CKSyncEngineState`.
- **Merge strategy:** Remote `ckSystemFields` always wins. `summary`, `rawTranscript`, and `actionItems` keep local value if non-nil.
- **Placeholder watchdog:** If placeholder meetings are still present >5 minutes after sync start, a background fetch is triggered to retry.
- **`unknownItem` error:** Treated as remote deletion — local record is deleted. Do not retry on this error.
- **`resetAndResync()`** — wipes the local DB and UserDefaults sync state, then re-downloads everything from CloudKit. Use only for full reset; all local-only data is lost.

**Pitfalls:**
- Never use raw SQL with `Date.timeIntervalSinceReferenceDate` in GRDB — always use Codable `update(db)`/`insert(db)`.
- `PRAGMA foreign_keys = OFF` is silently ignored inside GRDB `db.write {}` transactions.
- xcodegen regenerates `.entitlements` from `project.yml` — all entitlements must be in `entitlements.properties`, not added via Xcode UI.

## Remote Chunk Pipeline (iPhone/Watch → Mac)

iPhone/Watch recordings upload 10s/30s raw-audio chunks as `AudioChunk` CKRecords (direct CloudKit, bypassing CKSyncEngine). `RemoteMeetingProcessor` (macOS, 10s poll) claims, transcribes, and deletes chunks, then finalizes and summarizes the meeting. **Macs are treated as unreliable and intermittently available** — any Mac may sleep or die mid-work and another (or the same one, later) must be able to take over safely:

- **Chunk claims:** `claimChunk` CAS-updates status pending→processing using CloudKit's default `.ifServerRecordUnchanged`; per-record failures arrive in the *results dictionary*, not as thrown errors — always check them. Claims stale for >2 min are reset to pending (`resetStuckProcessingChunks`); startup/wake recovery uses the same threshold — never reset with `olderThan: 0` (steals other Macs' fresh claims → duplicated transcript text).
- **Idempotent transcription:** before and after transcribing, the segment window `[offsetSeconds, offset+duration)` is checked — if segments already exist there (another Mac processed it, or our pre-sleep attempt landed), the result is discarded instead of double-appended.
- **Retry cap:** 3 attempts per chunk per session, then the chunk is marked `status = "failed"` so it stops blocking finalization; failed leftovers are deleted at finalization (`deleteRemainingChunks`).
- **`appendRemoteSegment`** creates a placeholder meeting when the meeting record hasn't synced yet (chunks routinely outrun CKSyncEngine) — never let the FK constraint swallow segments.
- **Cross-Mac work claims:** finalization and summarization are guarded by `ProcessingClaim` marker records (`finalize_{meetingId}` / `summarize_{meetingId}`) — first Mac to create one wins; claims untouched for 10/15 min are presumed abandoned and stolen via CAS re-save. Claim creation fails OPEN on unexpected errors (e.g. record type missing from prod schema) so work still happens.
- **Summary janitor:** each poll also picks up recent (<48h) `.done` meetings with a transcript but no summary (finalizing Mac slept/crashed mid-summarize) — grace period 5 min after `endedAt`, 2 attempts per session.
- **Finalize fast-path guard:** only meetings this Mac saw `AudioChunk` records for are finalized promptly; other `.transcribing` meetings (possibly another device's live recording synced mid-drain) must be quiet for 5 min past their last segment. The local `RecordingSession.currentMeetingId` is never touched.
- **Interrupted-recording alert:** only offered for meetings in UserDefaults `locallyRecordedMeetingIds` (recorded on THIS Mac) — discarding a syncing iPhone meeting would delete it everywhere.

**Pitfalls:**
- ⚠️ **CloudKit prod schema:** the `ProcessingClaim` record type and the AudioChunk `"failed"` status value auto-create in the Development environment on first run, but the **record type must be deployed to Production** in CloudKit Console before a TestFlight/App Store release (claims fail open until then, reverting to pre-claim behavior).
- CKQuery results are paginated (~100 records) — always follow cursors (`fetchAll(matching:)` in `AudioChunkService`).
- After a successful CAS save, the in-memory CKRecord's change tag is stale — use the record returned in the save results for any follow-up CAS save.

## Bug Reporting

`Memgram/BugReport/` — in-app bug report form (Settings → Help tab).

- **`BugReportPayload.swift`** — `Codable` struct + `@MainActor BugReportPayloadBuilder`. Collects OSLog entries (last 30 min via `OSLogStore(scope: .currentProcessIdentifier)`), anonymous meeting metadata (up to 20 meetings), crash log (capped at 50 KB), and system info via `ProcessInfo`/`sysctlbyname`.
- **`BugReportSubmitter.swift`** — POSTs a formatted GitHub Issue to `ekabanov/memgram-bugs` via REST API. Payload embedded as a collapsible `json` fenced block in the issue body.
- **`BugReportView.swift`** — SwiftUI settings tab. Builds payload once in `.task {}`, reuses on submit.
- **`BugReportConfig.swift`** — **gitignored**. Must be created manually; contains `githubToken` (fine-grained PAT, `issues:write` on `ekabanov/memgram-bugs`).

**Pitfalls:**
- `OSLogStore.local()` requires a private entitlement — always use `OSLogStore(scope: .currentProcessIdentifier)`.
- `BugReportConfig.swift` must never be committed — it contains a live GitHub token.

## Automated Fix Pipeline

`ekabanov/memgram-bugs` is a private GitHub repo that receives bug reports from the app and automatically attempts to fix them via Claude Code.

**Flow:**
1. App submits a GitHub Issue to `memgram-bugs` (label `bug-report` added automatically)
2. GitHub Actions workflow (`.github/workflows/autofix.yml`) triggers on `issues: labeled` when label is `bug-report`
3. Extracts the JSON payload from the issue body (`extract-payload.py`), builds an agent prompt (`build-prompt.py` + `agent-prompt-template.md`), and runs `claude --model claude-sonnet-4-6 --print` in a full checkout of this repo
4. If the agent opens a PR against `ekabanov/Memgram`, the issue is labeled `automated-fix-opened`; otherwise `needs-human-review`

**Secrets required in `ekabanov/memgram-bugs`:**
- `ANTHROPIC_API_KEY` — Claude API key for the agent runner
- `MAIN_REPO_TOKEN` — Fine-grained PAT: `Contents: read/write` + `Pull requests: read/write` on `ekabanov/Memgram`

**Agent constraints (in `agent-prompt-template.md`):**
- Read `CLAUDE.md` first
- Fix at most 3 files; do not touch DB migrations
- Build must pass before opening a PR (`CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`)
- If root cause is unclear, comment on the issue instead of opening a PR

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

- **Default implementation:** wraps `complete()` — yields the full response as a single chunk. Used as fallback only.
- **Qwen implementation:** overrides `stream()` with `ChatSession.streamResponse(to:)` for true token-by-token output. Runs in `Task.detached` to avoid main actor deadlock with MLX's `AsyncMutex`. Buffers tokens until `</think>` closes if a think block appears.
- **SSE providers (Claude, OpenAI, Custom Server, Gemini):** use `URLSession.bytes(for:)` + `bytes.lines` to parse Server-Sent Events. Add `stream: true` to the request body. Parse `data:` prefixed JSON lines, skipping `[DONE]` sentinels.
- **Gemini SSE:** uses `streamGenerateContent?alt=sse` endpoint instead of `generateContent`.
- **SummaryEngine streaming:** `summarize()` builds an `onChunk: (String) -> Void` closure that strips `<think>` tags, suppresses updates while a `<think>` block is open (Qwen reasoning), and dispatches `streamingText[meetingId] = visible` to main actor. `summarizeShort` and `summarizeFinal` both use `provider.stream()` loops and call `onChunk` with the accumulated string after each token.
- **`streamingText: [String: String]`** — `@Published` on `SummaryEngine`. Set during generation, cleared by `defer` in `summarize()` (covers all exit paths including early returns and errors).
- **MeetingDetailView:** shows `streamingText[meetingId]` as live `Markdown` with a "Generating…" badge overlay while active; falls back to saved summary; skeleton while waiting for first tokens.
- **`<think>` suppression:** `onChunk` checks `hasPrefix("<think>") && !contains("</think>")` — no UI updates while the thinking block is still open, then content streams normally once `</think>` appears.
- **Qwen thinking disabled:** `ChatSession` is created with `additionalContext: ["enable_thinking": false]`, which is passed as a Jinja template variable and suppresses the think block entirely. The `<think>` filter in `stream()` remains as a safety net.

## Testing

`Tests/MemgramTests/` — Swift Testing suite (36 tests, 0 failures). Uses in-memory GRDB databases; no network, no CloudKit entitlement needed.

**Infrastructure (`Tests/MemgramTests/Infrastructure/`):**
- **`FakeCloudKitChannel`** — in-memory iCloud backend shared across test devices. Stores `CKRecord`s, detects conflicts, simulates push notifications. Controls: `holdPushes` (network partition), `conflictingRecordIDs`, `failNextSave`.
- **`FakeSyncTransport`** — implements `SyncTransport`. `flush()` builds records via `delegate.buildRecord`, uploads to channel, calls `delegate.didSend`. `receive(modifications:deletions:)` called by channel on push.
- **`TestSyncEnvironment`** — bundles one simulated device: in-memory `AppDatabase` + `MeetingStore` + `CloudSyncEngine` + `FakeSyncTransport`. `make(channel:)` for two-device tests; `makeLocal()` for single-DB tests.

**Test files:**
- **`MeetingStatusTests`** — 15 tests: status transitions (recording→transcribing→diarizing→done), interrupted detection, filter logic (placeholder hidden, interrupted shown), CRUD.
- **`SyncStatusTests`** — 11 tests: `pendingUpload` on create, `synced` after flush, `failed` on error, `serverRecordChanged` conflict re-enqueue, placeholder creation for orphaned segments, remote record normalization.
- **`TwoDeviceSyncTests`** — 10 tests: basic A→B sync, delayed push delivery, FK out-of-order delivery (segments before meetings), bidirectional, deletion, conflict resolution, reset/resync via `fetchChanges()`, error recovery, out-of-order delivery.

**Pitfalls:**
- `@Suite`/`@Test` macros are incompatible with `@available(macOS 14.0, *)` on the struct — omit `@available` since the test target already deploys to macOS 14.0.
- `AppDelegate.applicationDidFinishLaunching` bails out immediately when `XCTestBundlePath` env var is set — prevents Qwen preload, Parakeet downloads, and CloudKit init from running during tests.
- `CloudSyncEngine.container` is `lazy` — avoids `CKContainer` initialization (which requires CloudKit entitlement) in test instances that use `FakeSyncTransport`.
- Do NOT call `engine.applyRemoteRecord()` or `engine.reEnqueueOrphanedRecords()` from tests — both are `fileprivate`. Route incoming records through `transport.receive(modifications:deletions:)`; trigger re-enqueue via `engine.enqueueSave(table:id:)` or `engine.start()`.

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
