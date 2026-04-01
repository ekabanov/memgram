# Memgram Testing Suite — Design Spec

**Date:** 2026-04-01
**Status:** Approved

## Goal

Create a high-fidelity testing suite covering single-DB meeting status transitions and two-device CloudKit sync, with a `FakeCloudKitChannel` replacing real iCloud transport while preserving the full delegate event loop, change tag tracking, push notification simulation, and controlled delivery ordering.

---

## 1. Production Refactors

Minimal changes to make `AppDatabase`, `MeetingStore`, and `CloudSyncEngine` injectable for tests.

### 1.1 `SyncTransport` protocol

Abstracts what `CloudSyncEngine` needs from `CKSyncEngine`:

```swift
protocol SyncTransport: AnyObject {
    var delegate: SyncTransportDelegate? { get set }
    func enqueueSave(_ recordID: CKRecord.ID)
    func enqueueDelete(_ recordID: CKRecord.ID)
    func ensureZone(_ zoneID: CKRecordZone.ID)
    func fetchChanges() async throws
    var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
}
```

### 1.2 `SyncTransportDelegate` protocol

Mirrors `CKSyncEngineDelegate` callbacks so both real and fake transports call the same interface:

```swift
protocol SyncTransportDelegate: AnyObject {
    func buildRecord(table: String, id: String) -> CKRecord?
    func didSend(saved: [CKRecord], failed: [(CKRecord, CKError)])
    func didReceive(modifications: [CKRecord], deletions: [CKRecord.ID])
    func didSaveState(_ data: Data)
}
```

### 1.3 `CKSyncTransport`

Real implementation wrapping `CKSyncEngine`. Extracted from the current `CloudSyncEngine` internals. Conforms to `SyncTransport`. Used in production.

### 1.4 `AppDatabase` injectable init

Add a second initializer accepting a `DatabaseQueue` directly:

```swift
init(queue: DatabaseQueue) throws {
    self.dbQueue = queue
    try runMigrations()
}
```

The existing `private init()` and `static let shared` are unchanged.

### 1.5 `MeetingStore` injectable init

Add an initializer accepting dependencies:

```swift
init(db: AppDatabase, sync: CloudSyncEngine?) {
    self.db = db
    self.sync = sync
}
```

The existing `static let shared` uses the current singleton pattern.

### 1.6 `CloudSyncEngine` injectable init

Add an initializer accepting `AppDatabase` and `SyncTransport`:

```swift
init(db: AppDatabase, transport: SyncTransport) {
    self.db = db
    self.transport = transport
    // ... rest of init, using transport instead of creating CKSyncEngine
}
```

The existing `static let shared` creates a `CKSyncTransport` internally.

---

## 2. Test Infrastructure

### 2.1 `FakeCloudKitChannel`

Shared in-memory "iCloud" backend between two `FakeSyncTransport` instances.

**State:**
- `records: [CKRecord.ID: CKRecord]` — current cloud state
- `changeTags: [CKRecord.ID: Int]` — version counter per record for conflict detection
- `connectedTransports: [FakeSyncTransport]` — all registered devices

**Pending push queue:**
- `pendingPushes: [(target: FakeSyncTransport, records: [CKRecord], deletions: [CKRecord.ID])]`
- `holdPushes: Bool` — when true, pushes queue silently (simulates network partition)

**Error injection:**
- `failNextSave: CKError.Code?` — if set, next upload batch fails with this error
- `conflictingRecordIDs: Set<CKRecord.ID>` — records that will trigger `serverRecordChanged` on next upload

**Upload flow** (`receive(records:deletions:from:)` called by FakeSyncTransport):
1. For each record: check `changeTags[id]` vs record's tag
   - Stale tag → return `serverRecordChanged` with the current server record
   - Fresh or new → store record, increment change tag
2. Queue push for all other connected transports (unless `holdPushes`)
3. Return save results (saved + failed)

**Delivery controls:**
- `deliverPushes()` — delivers all pending pushes to target transports (calls their `fetchChanges()`)
- `deliverPushes(to transport:)` — deliver only to one specific transport
- `deliverOutOfOrder(_ recordIDs: [CKRecord.ID], to transport:)` — delivers specified records in the given order, overriding natural ordering
- `deliverSegmentsBeforeMeetings(to transport:)` — convenience for FK ordering tests

**Fetch all (reset/resync support):**
- When a transport calls `fetchChanges()` with no prior state, channel returns all records (simulates CKSyncEngine full fetch on first launch).

### 2.2 `FakeSyncTransport`

Implements `SyncTransport`. Connected to a `FakeCloudKitChannel`.

**State:**
- `pendingSaves: [CKRecord.ID]`
- `pendingDeletes: [CKRecord.ID]`
- `channel: FakeCloudKitChannel`

**`flush() async`** — processes the pending queue synchronously:
1. Calls `delegate?.buildRecord(table:id:)` for each pending save → collects `CKRecord`s
2. Sends records to `channel.receive(records:deletions:from:self)`
3. Channel returns results (saved/failed)
4. Calls `delegate?.didSend(saved:failed:)` with results
5. Clears pending queue

**`fetchChanges() async throws`** — called by channel during push delivery:
1. Channel provides the records and deletions for this transport
2. Calls `delegate?.didReceive(modifications:deletions:)`

### 2.3 `TestSyncEnvironment`

Bundles one "device" for tests:

```swift
struct TestSyncEnvironment {
    let db: AppDatabase          // in-memory GRDB
    let meetingStore: MeetingStore
    let engine: CloudSyncEngine
    let transport: FakeSyncTransport
}
```

**Factory:**
```swift
static func make(channel: FakeCloudKitChannel) throws -> TestSyncEnvironment
```

Creates an in-memory `AppDatabase` (full v4 schema), a `MeetingStore` backed by it, a `FakeSyncTransport` connected to the channel, and a `CloudSyncEngine` wired to all three.

---

## 3. Test Files and Scenarios

### 3.1 `MeetingStatusTests.swift` — single-DB, no sync

**Status transitions:**
- Create meeting → status = .recording
- updateStatus → .transcribing → .diarizing → .done (full pipeline)
- finalizeMeeting → status = .done, rawTranscript set

**Interrupted detection:**
- Meeting stuck in .recording at startup → interruptedMeetings() returns it
- Meeting stuck in .transcribing → same
- Meeting stuck in .diarizing → same
- Meeting in .done → NOT returned by interruptedMeetings()
- recoverMeeting → status = .interrupted

**Filter logic:**
- .placeholder meetings hidden
- .done with empty rawTranscript shown
- .done with nil rawTranscript shown
- .interrupted shown
- .recording and .transcribing shown

**Edge cases:**
- finalizeMeeting with empty string transcript → status = .done, rawTranscript = ""
- discardMeeting removes meeting and segments
- saveSummary then fetchMeeting → summary persisted
- updateTitle persists

### 3.2 `SyncStatusTests.swift` — single-device sync lifecycle

**enqueueSave behaviour:**
- enqueueSave writes pendingUpload to DB even when transport has not started
- enqueueSave for non-meeting table (segments) does NOT write sync_status
- enqueueSave on already-synced meeting resets to pendingUpload

**Upload lifecycle:**
- flush → transport calls buildRecord → delegate.didSend(saved:) → sync_status = .synced
- After flush: uploadingIds is empty, pendingCount = 0

**Error paths:**
- Permanent error → sync_status = .failed, failedCount incremented
- serverRecordChanged → applyRemoteRecord with server version, re-enqueue as pendingUpload, uploadingIds cleared during retry
- unknownItem → meeting deleted locally

**applyRemoteRecord normalization:**
- Incoming status = "done", rawTranscript = nil → local status = .interrupted
- Incoming status = "done", rawTranscript = "text" → local status = .done (no normalization)
- Incoming record → sync_status = .synced

**Placeholder lifecycle:**
- Segment arrives before meeting → placeholder created with sync_status = .placeholder
- Meeting record arrives → placeholder promoted to sync_status = .synced
- Stale placeholder (>5 min) triggers fetch

**Startup recovery:**
- reEnqueueOrphanedRecords finds meetings with sync_status = .pendingUpload
- Meetings with sync_status = .synced are NOT re-enqueued

### 3.3 `TwoDeviceSyncTests.swift` — end-to-end

**Basic sync:**
- A creates meeting → flush A → deliverPushes → B has meeting with all fields correct
- B's copy has sync_status = .synced
- A's copy has sync_status = .synced after flush

**Meeting with segments:**
- A creates meeting + appends 3 segments → flush A → deliverPushes → B has meeting + 3 segments
- Segments have correct speaker, text, timestamps

**FK ordering:**
- A creates meeting + segment → flush A
- `channel.deliverSegmentsBeforeMeetings(to: transportB)` → segment arrives first → placeholder created
- Then meeting arrives → placeholder replaced with real meeting, segment FK intact

**Out-of-order delivery:**
- A creates meetings M1, M2, M3 → flush A
- `channel.deliverOutOfOrder([M3.id, M1.id, M2.id], to: transportB)` → all three arrive, correct data regardless of order

**Delayed delivery (network partition):**
- `channel.holdPushes = true`
- A creates meeting → flush A → no push to B
- B has 0 meetings
- `channel.holdPushes = false; channel.deliverPushes()` → B now has meeting
- Verify sync_status = .synced on both sides

**Conflict resolution:**
- A and B both have meeting M (synced)
- A updates title to "A's title" → flush A
- B updates title to "B's title" → flush B → receives serverRecordChanged
- B applies server record (A's version) → B's title = "A's title"
- B re-enqueues with its own changes
- Verify status rank preservation: if A has .done and remote sends .transcribing, A keeps .done

**Summary preservation on conflict:**
- A generates summary locally
- B has same meeting with summary = nil in CloudKit
- B downloads A's version → merged.summary = A's summary (not nil)
- Reverse: A has summary, remote record has different summary → keep local if non-nil

**Deletion:**
- A creates meeting → syncs to B → both have it
- A deletes meeting → flush A → deliverPushes → B's copy removed
- B's meeting list count = 0

**Bidirectional:**
- A creates meeting MA, B creates meeting MB independently
- flush A, flush B, deliverPushes
- Both devices have both MA and MB
- sync_status = .synced on both for both meetings

**Reset/resync:**
- A has 5 meetings synced to channel
- B starts fresh (no prior state) → B.engine.start() → fetchChanges → receives all 5
- All 5 have sync_status = .synced on B

**Error recovery:**
- `channel.failNextSave = .networkFailure`
- A creates meeting → flush → didSend reports failure → sync_status = .failed
- `channel.failNextSave = nil`
- A re-enqueues → flush → succeeds → sync_status = .synced

---

## 4. Test Target Setup

### 4.1 `project.yml` additions

New test target `MemgramTests`:
- Platform: macOS 14.0+
- Framework: Swift Testing (`import Testing`)
- Dependencies: Memgram target + CloudKit framework
- Sources: `Tests/MemgramTests/`
- `@testable import Memgram` for internal access

### 4.2 File structure

```
Tests/MemgramTests/
  Infrastructure/
    SyncTransport.swift         # protocol definitions
    CKSyncTransport.swift       # real implementation (also used in production)
    FakeSyncTransport.swift     # test implementation
    FakeCloudKitChannel.swift   # shared in-memory iCloud
    TestSyncEnvironment.swift   # device factory
  MeetingStatusTests.swift      # single-DB status transitions
  SyncStatusTests.swift         # single-device sync lifecycle
  TwoDeviceSyncTests.swift      # two-device end-to-end
```

Note: `SyncTransport.swift` and `CKSyncTransport.swift` will live in the main Memgram target (not Tests) since production code uses them. They are listed here for completeness.

### 4.3 Production files modified

| File | Change |
|---|---|
| `Memgram/Database/AppDatabase.swift` | Add `init(queue:)` for in-memory test DB |
| `Memgram/Database/MeetingStore.swift` | Add `init(db:sync:)` for dependency injection |
| `Memgram/Sync/CloudSyncEngine.swift` | Use `SyncTransport` protocol; add `init(db:transport:)` |
| `Memgram/Sync/SyncTransport.swift` | New — protocol definitions |
| `Memgram/Sync/CKSyncTransport.swift` | New — real CKSyncEngine wrapper |
| `project.yml` | Add MemgramTests target |

---

## 5. Non-goals

- UI testing (SwiftUI views, cloud icons, banners)
- Audio/transcription pipeline testing (WhisperKit, Parakeet, SpeakerDiarizer)
- Performance/load testing
- watchOS sync testing
