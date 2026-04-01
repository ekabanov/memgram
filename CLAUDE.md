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

Memgram is a macOS menu bar app (`LSUIElement: true`) that records meetings, transcribes locally via Parakeet (default) or WhisperKit, performs speaker diarization, and generates AI summaries. All processing is offline.

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
  SpeakerDiarizer (batch post-processing, two Sortformer instances)
         ↓ speaker labels per segment
  SummaryEngine (background) → normaliseSpeakerLabels() → MeetingStore.saveSummary → meetingDidUpdate notification
```

**System audio:** CoreAudioTapCapture on macOS 14.4+, ScreenCaptureKitCapture fallback. `kAudioObjectSystemObject` is NOT a valid process object for `CATapDescription` — always use `PermissionsManager.audioProcessObjectIDs()`.

**Transcription:** Backend selectable in **Settings → Recording**. Default is Parakeet (ANE). WhisperKit auto-downloads models; model auto-selected by `WhisperModelManager.autoSelectedModel` based on RAM + `preferMultilingual` flag. Users only see English/Multilingual toggle — no model list. `TranscriptionBackendManager` tracks backend preference and Parakeet/diarizer loading state.

**LLM backends:** Qwen (local MLX via `mlx-swift-lm`), Custom Server (OpenAI-compatible — covers Ollama/LM Studio/vLLM), Claude, OpenAI, Gemini. `LLMProviderStore.currentProvider` delegates to `providerFor(selectedBackend)`. API keys in Keychain only. All backends stream tokens via `provider.stream()` — cloud providers use SSE, Qwen uses `ChatSession.streamResponse()`.

**SummaryEngine:** `@MainActor ObservableObject`. `activeMeetingIds: Set<String>` tracks in-progress jobs — observed by UI for spinners. `summarize()` runs LLM off main (awaits provider), saves to DB, then calls `generateTitle()`. Title generation runs AFTER `activeMeetingIds.remove()` so progress clears immediately.

**MeetingDetailView:** Summary rendered via `swift-markdown-ui` (`Markdown(summary).markdownTheme(.gitHub)`). Tab bar: Summary (default) | Transcript. Local transcript search with `filteredSegments`. Delete/Copy in header `⋯` menu.

## Transcription Backends

`TranscriberProtocol` abstracts over two backends selectable in Settings → Recording:

- **`ParakeetTranscriber`** — FluidAudio ANE-based model. Default. No model download required; model is bundled or cached via FluidAudio. Lower latency than Whisper on Apple Silicon.
- **`WhisperTranscriber`** — WhisperKit with Metal decoder + ANE encoder. Fallback; supports multilingual. Auto-downloads model on first use.

**`AudioChannelUtils.selectDominantChannel()`** — before feeding audio to the transcription backend, picks the louder of mic (L) and system (R) channels. Prevents transcription of both channels when only one has speech, which would double-transcribe echo.

**`TranscriptionBackendManager`** — `@MainActor ObservableObject`. Persists backend choice in UserDefaults. Tracks loading state for Parakeet and diarizer (shown in Settings → Recording). Instantiates the active `TranscriberProtocol` implementation on demand.

## Speaker Diarization

`SpeakerDiarizer` (`Memgram/Diarization/`) runs batch post-processing after transcription drains. Requires macOS 14+.

- **Two Sortformer instances** (FluidAudio): one for mic channel, one for system audio channel. Each returns speaker embeddings + time-coded segments independently.
- **Echo suppression:** mic segments that occur during system-audio-dominant periods are attributed to the remote speaker rather than a local one. Prevents echo doubling in the speaker labels.
- **Snapshot:** takes a 5-minute evenly-sampled snapshot of the recording for diarization (not the full audio). Keeps memory use bounded.
- **Labels:** `Room 1`/`Room 2` for in-room speakers (mic channel), `Remote 1`/`Remote 2` for remote participants (system channel).
- **`SpeakerEnrollmentStore`** — saves a display name + 5-second voice sample per enrolled speaker. During diarization, enrolled speaker embeddings are compared to detected clusters; best match replaces the generic label (e.g. `Room 1` → `Alice`).
- **Onboarding:** `enrollVoice` step inserted between `systemAudio` and `done` for first-run voice enrollment.
- **`normaliseSpeakerLabels()` in `SummaryEngine`** — pre-processes transcript before LLM call: maps `Room`/`Remote` labels to `Speaker A`/`B`/`C` etc., appends a mapping hint so the LLM can resolve real names from calendar attendees + enrollment data.

**Pitfalls:**
- Sortformer has a 4-speaker cap per channel (2 local + 2 remote max).
- There is no persistent diarizer state between meetings — enrolled voice samples must be re-fed to the diarizer for each meeting at diarization time. Do not cache diarizer instances across meetings.
- Audio must be fully drained before `SpeakerDiarizer` runs — do not call it mid-recording.

## Package Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| GRDB | 6.x | SQLite (WAL, FTS5, `PRAGMA foreign_keys = ON`) |
| WhisperKit | 0.9+ | Transcription (Metal decoder + ANE encoder) |
| FluidAudio | main | Parakeet transcription (ANE) + Sortformer speaker diarization |
| MLXSwiftLM | branch `main` | Qwen local inference |
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
- **FK ordering:** Segments/speakers may arrive before their parent meeting from CloudKit. `applyRemoteRecord` creates placeholder meetings to satisfy FK constraints. Incoming records within a batch are sorted: meetings first, then segments/speakers.
- **Initial upload:** On first launch (no sync state in UserDefaults), all existing records are enqueued for upload. On subsequent launches, orphaned records (those without `ck_system_fields`) are also re-enqueued.
- **What does NOT sync:** `embeddings`, `segments_fts` (rebuilt by triggers), WhisperKit/LLM models.
- **State persistence:** `CKSyncEngine.State.Serialization` JSON-encoded in UserDefaults key `CKSyncEngineState`. Note: on this machine, UserDefaults writes to `~/Library/Preferences/com.memgram.app.plist` (not the sandboxed container path).
- **Merge strategy:** Remote `ckSystemFields` always wins. `summary`, `rawTranscript`, and `actionItems` keep local value if non-nil (prevents remote nil from overwriting a locally generated summary).
- **Placeholder watchdog:** If placeholder meetings (no title, created by FK pre-seeding) are still present >5 minutes after sync start, a background fetch is triggered to retry.
- **`unknownItem` error:** Treated as remote deletion — local record is deleted. Do not retry on this error.
- **`resetAndResync()`** — wipes the local DB and UserDefaults sync state, then re-downloads everything from CloudKit. Use only for full reset; all local-only data is lost.

**Pitfalls:**
- Never use raw SQL with `Date.timeIntervalSinceReferenceDate` in GRDB — always use Codable `update(db)`/`insert(db)`.
- `PRAGMA foreign_keys = OFF` is silently ignored inside GRDB `db.write {}` transactions.
- xcodegen regenerates `.entitlements` from `project.yml` — all entitlements must be in `entitlements.properties`, not added via Xcode UI.

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
