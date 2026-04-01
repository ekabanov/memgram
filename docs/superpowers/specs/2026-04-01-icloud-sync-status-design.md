# iCloud Sync Status — Design Spec

**Date:** 2026-04-01  
**Status:** Approved

## Goal

Surface iCloud sync health visibly across Mac and iOS: a cloud icon on every meeting row showing whether it is synced, pending, uploading, or failed; and a global banner in the meeting list when action is needed. Replace all fragile inference logic (ckSystemFields presence, title == "Syncing…", rawTranscript == nil) with explicit semantic DB columns.

---

## 1. Data Model

### 1.1 New column: `sync_status` on `meetings`

```swift
enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pendingUpload = "pending_upload"
    case placeholder
    case synced
    case failed
}
```

| Value | Meaning | Replaces |
|---|---|---|
| `pendingUpload` | Real meeting not yet acknowledged by CloudKit | `ckSystemFields == nil && title != "Syncing…"` |
| `placeholder` | FK pre-seed row awaiting parent record from CloudKit | `ckSystemFields == nil && title == "Syncing…"` |
| `synced` | CloudKit has acknowledged this record | `ckSystemFields != nil` |
| `failed` | Upload failed permanently or with retriable error | (not tracked previously) |

`ckSystemFields` is retained — it carries CloudKit record metadata (change tag, etc.) needed for conflict resolution. `sync_status` is local-only and never stored in CloudKit records.

### 1.2 Expanded `MeetingStatus`

```swift
enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording
    case transcribing
    case diarizing    // new — Sortformer running
    case done
    case interrupted  // new — recording stopped without transcript
    case error
}
```

| New value | Meaning | Replaces |
|---|---|---|
| `diarizing` | SpeakerDiarizer running post-transcription | `SpeakerDiarizer.isDiarizing(meetingId)` in-memory check |
| `interrupted` | Meeting ended without rawTranscript | `status == .done && rawTranscript == nil` |

`summarizing` remains in-memory only (`SummaryEngine.activeMeetingIds`) — it is fast and transient.

### 1.3 Status ordering for conflict resolution

```swift
let statusOrder: [MeetingStatus] = [.recording, .transcribing, .diarizing, .done, .interrupted, .error]
```

`interrupted` sits after `done` so a late-arriving `done` from CloudKit does not overwrite a locally-detected `interrupted`.

### 1.4 Schema migration strategy

No delta migration. Add a new GRDB migration version that drops the `meetings`, `segments`, and `speakers` tables and recreates them with the new schema. Clear `CKSyncEngineState` from UserDefaults on first launch after the version bump. Re-download everything from CloudKit. `applyRemoteRecord` populates `sync_status` and normalises `MeetingStatus` on ingest (see §2.3).

---

## 2. CloudSyncEngine

### 2.1 Published state

```swift
@Published var uploadingIds: Set<String> = []  // in-flight records, drives row animation
@Published var pendingCount: Int = 0           // drives global header
@Published var failedCount: Int = 0            // drives global header
```

`pendingCount` and `failedCount` are refreshed from the DB after every batch write (same point where `meetingDidUpdate` is posted).

### 2.2 State transitions

| Event | `sync_status` written | `uploadingIds` |
|---|---|---|
| `enqueueSave()` | `.pendingUpload` | — |
| `willSendChanges` (batch about to upload) | — | add IDs |
| `updateSystemFields()` — CloudKit ack | `.synced` | remove ID |
| `applyRemoteRecord()` — new record from CloudKit | `.synced` | — |
| Placeholder created (FK pre-seed) | `.placeholder` | — |
| Placeholder promoted by real record | `.synced` | — |
| `unknownItem` error | `.failed` | remove ID |
| Permanent `serverRecordChanged` / other terminal error | `.failed` | remove ID |

### 2.3 `applyRemoteRecord` normalization

When a meeting record arrives from CloudKit:

1. Set `sync_status = .synced`.
2. If `status == .done && rawTranscript == nil` → write `status = .interrupted` locally. CloudKit retains `"done"` — this is a read-time normalisation only, no re-upload.

### 2.4 Query simplifications

| Before | After |
|---|---|
| `ckSystemFields == nil AND status IN (done,error) AND title != "Syncing…"` | `sync_status == .pendingUpload` |
| `ckSystemFields == nil AND title == "Syncing…"` | `sync_status == .placeholder` |
| `ckSystemFields == nil AND title == "Syncing…" AND started_at < cutoff` | `sync_status == .placeholder AND started_at < cutoff` |
| `localDone.filter { !fetched.contains($0.id) }` (set arithmetic in reconcileAfterReset) | Unnecessary — after nuke+resync all local meetings come from CloudKit with `sync_status = .synced`; `reconcileAfterReset` can be removed |

---

## 3. Recording Pipeline

### 3.1 `diarizing` status

`SpeakerDiarizer` sets `status = .diarizing` before running and `status = .done` on completion. This replaces the `SpeakerDiarizer.isDiarizing(meetingId)` in-memory check in the row view.

### 3.2 `interrupted` status

Set in two places:

- **`loadInterruptedMeetings()` on startup** — meetings stuck in `.recording`, `.transcribing`, or `.diarizing` are set to `.interrupted` (previously set to `.done`).
- **`applyRemoteRecord()` normalization** — incoming `status == .done && rawTranscript == nil` → written as `.interrupted` locally.

---

## 4. Per-Row UI (Mac + iOS)

### 4.1 Cloud icon

A small SF Symbol trailing in each row. Hidden for `.placeholder` rows (which are also hidden from the list entirely — see §4.3).

| Condition | SF Symbol | Color |
|---|---|---|
| `syncStatus == .synced` | `icloud.fill` | `.secondary` |
| `syncStatus == .pendingUpload` + in `uploadingIds` | `icloud.and.arrow.up.fill` | `.secondary` + pulse animation |
| `syncStatus == .pendingUpload` + not uploading | `icloud.and.arrow.up` | `.secondary` |
| `syncStatus == .failed` | `exclamationmark.icloud.fill` | `.red` |

### 4.2 Status dot and subtitle

Clean switch on `MeetingStatus` — no nil checks, no in-memory isDiarizing calls:

```swift
// Status dot color
switch meeting.status {
case .recording:                return .red
case .transcribing, .diarizing: return .orange
case .done:                     return .green
case .interrupted:              return .secondary
case .error:                    return Color.red.opacity(0.5)
}

// Subtitle
switch meeting.status {
case .recording:    return "\(time) · Recording…"
case .transcribing: return "\(time) · Transcribing…"
case .diarizing:    return "\(time) · Identifying speakers…"
case .interrupted:  return "\(time) · Interrupted"
case .error:        return "\(time) · Error"
case .done:
    if activeMeetingIds.contains(meeting.id) { return "\(time) · Summarising…" }
    let mins = Int((meeting.durationSeconds ?? 0) / 60)
    return mins > 0 ? "\(time) · \(mins)m" : time
}
```

### 4.3 Meeting list filter

```swift
meetings = all.filter { $0.syncStatus != .placeholder }
```

All real meetings are shown regardless of transcript content. Placeholder rows are always hidden.

---

## 5. Global Indicator

### 5.1 Mac — main window meeting list header

Shown when `CloudSyncEngine.shared.pendingCount > 0 || CloudSyncEngine.shared.failedCount > 0`. Hidden otherwise (no persistent "all synced" confirmation).

- **Pending only:** `icloud.and.arrow.up` · "Syncing \(n) meeting…" (grey)
- **Failed only:** `exclamationmark.icloud` · "\(n) meeting failed to sync" (red)
- **Both:** failed message takes prominence; pending count shown below

### 5.2 iOS — meeting list banner

Same component, shown as a banner above the list using the same `pendingCount` / `failedCount` from `CloudSyncEngine.shared`.

---

## 6. Files Affected

| File | Change |
|---|---|
| `Memgram/Database/Meeting.swift` | Add `SyncStatus` enum; expand `MeetingStatus`; add `syncStatus` field |
| `Memgram/Database/AppDatabase.swift` | Bump migration version, new schema (no migration code) |
| `Memgram/Sync/CloudSyncEngine.swift` | Add published state; set `sync_status` at all transitions; simplify queries; normalize on `applyRemoteRecord` |
| `Memgram/Transcription/SpeakerDiarizer.swift` | Set `.diarizing` before run, `.done` after |
| `Memgram/Audio/RecordingSession.swift` | `loadInterruptedMeetings` sets `.interrupted` not `.done` |
| `Memgram/UI/MainWindow/MeetingListView.swift` | Simplified filter; add global header; update `MeetingRowView` |
| `Memgram/UI/MenuBar/PopoverView.swift` | No change — sync cards unaffected |
| iOS `MeetingRow` | Add cloud icon; same status switch logic |
| iOS meeting list | Add global banner |
