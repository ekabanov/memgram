# Memgram iPhone & Watch Companion App Design

## Goal

Add an iPhone app that records meetings, shows meetings and summaries offline, and delegates transcription/summarization to the Mac via CloudKit. Add a Watch app for recording only. Audio is uploaded in 30-second chunks for near-real-time transcript delivery and deleted after processing.

---

## Architecture Overview

```
Watch                     iPhone                         Mac
──────                    ──────                         ───
Record audio ──────────→  Receives via                   (existing app)
(.m4a file +              WatchConnectivity
CalendarContext)          │
                          ├─ Chunks audio (30s)
                          ├─ Uploads CKAssets ──────────→  RemoteMeetingProcessor
                          │                                ├─ Downloads chunk
                          │                                ├─ Transcribes (WhisperKit)
Record directly ─────────→├─ Creates meeting record        ├─ Writes segments → CloudKit
on iPhone too             │                                ├─ Deletes audio asset
                          │                                └─ On meeting complete:
                          │                                   ├─ Builds rawTranscript
                          │                                   ├─ SummaryEngine.summarize()
                          │                                   └─ Writes summary → CloudKit
                          │
                          ├─ GRDB database (offline)
                          ├─ CloudSyncEngine (same as Mac)
                          ├─ Segments arrive → live transcript
                          └─ Summary arrives → meeting done
```

All data flows through the shared CloudKit container `iCloud.com.memgram.app` in the `MemgramZone` custom zone. No custom server, no direct device-to-device connection.

---

## Project Structure

### MemgramCore (shared Swift package)

Extract from the existing Mac codebase into a local Swift package linked by all three targets:

| Module | Contents |
|--------|----------|
| **Models** | `Meeting`, `MeetingSegment`, `Speaker`, `MeetingEmbedding`, `CalendarContext`, `MeetingStatus`, `AudioChannel` |
| **Database** | `AppDatabase` (schema + migrations), `MeetingStore` (CRUD) |
| **Sync** | `CloudSyncEngine` (CKSyncEngine wrapper) |
| **Calendar** | `CalendarManager`, `CalendarNotificationService` |
| **Export** | `PDFExporter` |
| **Logging** | `Log.swift` (`Logger.make()`) |
| **BugReport** | `BugReportPayload`, `BugReportSubmitter`, `BugReportView` |

Platform guards (`#if os(macOS)` / `#if os(iOS)`) where needed — e.g. `PDFExporter` uses `NSTextView` on Mac, would need `UITextView` equivalent on iOS.

### Platform-specific code (stays in each target)

| Mac | iPhone | Watch |
|-----|--------|-------|
| WhisperKit / TranscriptionEngine | AVAudioSession recording | AVAudioSession recording |
| MLX / QwenLocalProvider | AudioChunkUploader | WatchConnectivity transfer |
| StereoMixer, MicrophoneCapture | RecordingView | RecordingView (minimal) |
| CoreAudioTapCapture | MeetingListView, MeetingDetailView | — |
| RemoteMeetingProcessor (new) | WatchConnectivity receiver | — |
| AppDelegate (menu bar) | CalendarManager (iOS EventKit) | Calendar fetch from iPhone |

---

## CloudKit Audio Chunk Schema

New record type in `MemgramZone`:

**Record type: `AudioChunk`**
Record ID format: `audiochunks_{uuid}`

| Field | Type | Notes |
|-------|------|-------|
| `meetingId` | String | Links to meeting record |
| `chunkIndex` | Int64 | Ordering (0, 1, 2…) |
| `audioData` | CKAsset | 16kHz mono Float32 PCM, ~30s ≈ 1.9 MB |
| `status` | String | `pending` / `done` |
| `offsetSeconds` | Double | Timestamp offset within the meeting |

Audio chunks do NOT sync to the local GRDB database. They exist only in CloudKit, transiently.

---

## Mac: RemoteMeetingProcessor

New component added to the Mac app. Starts at launch, runs in background.

### Watching for chunks

Uses `CKSubscription` (or polls via `CKSyncEngine` fetch cycle) for new `AudioChunk` records with `status = pending`.

On new chunk:
1. Download `audioData` CKAsset to temp file
2. Read as Float32 array (16kHz mono)
3. Create a dedicated `TranscriptionEngine` instance (separate from local recording's instance)
4. Call `transcriptionEngine.transcribe(audioArray:, offsetSeconds:)` — a new method that transcribes a raw buffer and returns `[TranscriptSegment]` without the full prepare/chunk pipeline
5. Write segments to CloudKit via `MeetingStore` + `CloudSyncEngine`
6. Update chunk `status = done`
7. Delete the `AudioChunk` record (removes the CKAsset from iCloud storage)

### Finalizing a remote meeting

When `CloudSyncEngine` receives a meeting status change to `transcribing`:
1. Verify all audio chunks for that meeting are `status = done` (or wait/poll until they are)
2. Build `rawTranscript` from all segments for that meeting
3. Save `rawTranscript` via `MeetingStore.finalizeMeeting()`
4. Call `SummaryEngine.shared.summarize(meetingId:)` — generates summary + auto-title
5. Update meeting status to `done`
6. Summary + title sync back to iPhone via existing CloudKit sync

### Concurrency

`RemoteMeetingProcessor` handles one chunk at a time per meeting (sequential by `chunkIndex`). Multiple meetings can be processed in parallel. Uses a `Task` per meeting with a serial chunk queue.

---

## iPhone App

### Data layer

Local GRDB database with the same schema as Mac. `CloudSyncEngine` syncs meetings, segments, and speakers. Fully offline for reading. No embeddings table (no semantic search on iPhone v1).

### Screens

**1. Meetings List**
- Grouped by date (same as Mac)
- Title, duration, status badge (recording / transcribing / done)
- Pull-to-refresh triggers CloudKit fetch
- Tap opens Meeting Detail

**2. Meeting Detail**
- Summary tab (Markdown rendered) + Transcript tab
- Export PDF / Share (same as Mac)
- Read-only in v1 — no regenerate, no speaker rename

**3. Recording**
- Accessed via a prominent button in the navigation bar or tab bar
- Shows upcoming calendar event (if any) with event title and attendees
- Large Record / Stop button
- Elapsed time counter
- Live transcript view as segments arrive from Mac
- "Uploading…" / "Waiting for Mac…" / "Processing…" status indicator

### Recording flow

1. **Start**: Create `Meeting` record (status: `recording`). If a calendar event matches the current time (via `CalendarManager`), attach `CalendarContext`.
2. **Capture**: `AVAudioSession` with `.record` category. Capture at 16kHz mono. Buffer into 30-second chunks.
3. **Upload**: Each chunk → create `AudioChunk` CKRecord with CKAsset → upload. Retry on failure. Queue pending chunks locally (file references in a lightweight queue persisted to UserDefaults).
4. **Stop**: Upload any remaining partial chunk. Update meeting status to `transcribing` in CloudKit.
5. **Live transcript**: New `TranscriptSegment` records arrive via `CloudSyncEngine` during recording. Display them in a scrolling transcript view.
6. **Completion**: Meeting status changes to `done` (set by Mac after summarization). Summary appears in Meeting Detail.

### Calendar integration

`CalendarManager` runs on iOS using the same EventKit code as Mac. Reads from the system calendar store (same Google/iCloud/Exchange accounts added in iOS Settings).

**Shared calendar selection:** The `selectedCalendarIds` set is persisted in CloudKit (as a settings record) rather than local UserDefaults. Both Mac and iPhone read/write from the same CloudKit record so the selection stays in sync. If empty, all calendars are monitored (existing default).

### Logging and bug reporting

Same `Logger.make()` infrastructure as Mac — all logs go through `OSLog` with subsystem `com.memgram.app` and per-module categories.

`BugReportView` available from iPhone Settings screen. Same payload structure as Mac: collects `OSLogStore` entries (last 30 min), anonymous meeting metadata, system info via `ProcessInfo`/`sysctlbyname`. Submits to `ekabanov/memgram-bugs` as a GitHub Issue. Uses the same `BugReportConfig` for the token. `BugReportConfig.swift` (gitignored) is shared across Mac and iOS targets — same file reference in both.

---

## Watch App

### One screen: Recording

- Complication for quick launch
- Shows upcoming event title (fetched from iPhone) if available
- Large Record / Stop button
- Elapsed time counter
- Status label: "Recording" / "Sending to iPhone…" / "Done"
- No meetings list, no transcript, no summary view

### Recording flow

1. **On appear**: Send `WatchConnectivity.sendMessage(["requestCalendarContext": true])` to iPhone. iPhone queries `CalendarManager` and replies with `CalendarContext` JSON (or nil).
2. **Record**: `AVAudioSession` records to a temp `.m4a` file on Watch. Compressed audio — Watch storage is limited.
3. **Stop**: Transfer to iPhone via `WatchConnectivity.transferFile(fileURL, metadata:)` where metadata contains `calendarContext` JSON and `startedAt` timestamp. Transfer is background-safe and survives brief disconnects.
4. **iPhone receives**: Converts `.m4a` to 16kHz mono Float32 PCM → chunks into 30s segments → creates meeting record with `CalendarContext` → uploads chunks to CloudKit. Same path as iPhone-recorded audio from this point.
5. **Status**: iPhone sends completion updates back to Watch via `sendMessage()`.

### Calendar context

Watch does not access EventKit directly. It requests calendar context from the paired iPhone at recording start. If iPhone is unreachable, recording proceeds without calendar context — the summary will still work, just without attendee/title metadata.

---

## Shared Calendar Selection Sync

Current state: `selectedCalendarIds` is stored in `UserDefaults` on Mac.

New approach: Store `selectedCalendarIds` as a CloudKit record:

**Record type: `UserSettings`** (single record, shared zone)
| Field | Type |
|-------|------|
| `selectedCalendarIds` | List<String> |

`CalendarManager` reads/writes this record. Changes on either device sync to the other. Fallback: if CloudKit is unreachable, use local cache.

---

## Implementation Phases

### Phase 1: MemgramCore + iPhone Read-Only

Extract shared code into `MemgramCore`. Create iOS target. Implement:
- Meetings list + Meeting detail (summary + transcript tabs)
- CloudKit sync (reuse `CloudSyncEngine`)
- Export PDF / Share
- OSLog logging + BugReportView

**Deliverable:** iPhone app that shows all meetings recorded on Mac, fully offline.

### Phase 2: iPhone Recording + Mac RemoteMeetingProcessor

Add recording to iPhone:
- `AVAudioSession` capture + 30s chunking
- `AudioChunkUploader` → CloudKit CKAssets
- Live transcript view during recording
- Calendar integration (EventKit on iOS)

Add to Mac:
- `RemoteMeetingProcessor` — chunk watcher, transcriber, finalizer
- `CKSubscription` for audio chunks

Sync `selectedCalendarIds` via CloudKit.

**Deliverable:** Full iPhone recording with Mac-delegated transcription and summarization.

### Phase 3: Watch Recording

- watchOS target with WatchConnectivity
- Record to file, transfer to iPhone
- Calendar context fetch from iPhone
- iPhone receives and routes through Phase 2 upload path

**Deliverable:** Watch records meetings, routes through iPhone to Mac for processing.

---

## What is NOT in scope

- On-device transcription on iPhone (no WhisperKit on iOS)
- On-device summarization on iPhone (no MLX/Qwen on iOS)
- Speaker rename or summary regeneration on iPhone
- Semantic search on iPhone
- Multiple Mac processing (assumes one Mac per iCloud account)
- App Store distribution (TestFlight / direct install for now)
- Push notifications to iPhone when summary is ready (CloudKit sync handles this naturally)
