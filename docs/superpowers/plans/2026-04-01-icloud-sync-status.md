# iCloud Sync Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit `SyncStatus` and expanded `MeetingStatus` DB columns, replace all fragile inference logic in CloudSyncEngine, and surface iCloud sync state as cloud icons per meeting row and a global banner in the meeting list on Mac and iOS.

**Architecture:** A new `sync_status` column on `meetings` carries `pendingUpload / placeholder / synced / failed`. `MeetingStatus` gains `diarizing` and `interrupted` to replace in-memory checks and `rawTranscript == nil` inference. `CloudSyncEngine` exposes `@Published` aggregate counts and an `uploadingIds` set for per-row animation. The DB is nuked via a drop-and-recreate migration; CloudKit re-download repopulates with correct statuses.

**Tech Stack:** Swift, SwiftUI, GRDB 6.x, CloudKit CKSyncEngine, macOS 14+

---

## File Map

| File | Change |
|---|---|
| `Memgram/Database/Meeting.swift` | Add `SyncStatus` enum; add `diarizing`/`interrupted` to `MeetingStatus`; add `syncStatus` field |
| `Memgram/Database/AppDatabase.swift` | Add v4 migration (drop+recreate); expose `needsCloudResync` flag |
| `Memgram/AppDelegate.swift` | Clear `CKSyncEngineState` UserDefaults key when `needsCloudResync` |
| `Memgram/Database/MeetingStore.swift` | Update `interruptedMeetings()` for new statuses; add `updateSyncStatus()` |
| `Memgram/Sync/CloudSyncEngine.swift` | Add `@Published` state; set `sync_status` at all transitions; simplify queries; remove `reconcileAfterReset` |
| `Memgram/Audio/RecordingSession.swift` | Replace `diarizingMeetingId` with DB status `.diarizing`/`.done`; update `recoverMeeting` |
| `Memgram/UI/MainWindow/MeetingListView.swift` | Simplified filter; clean `MeetingRowView` switches; add cloud icon; add `SyncStatusHeader` |
| `MemgramMobile/UI/MobileMeetingListView.swift` | Simplified filter; cloud icon in `MeetingRow`; update `StatusBadge`; add sync banner |

---

## Task 1: Data model — Meeting.swift

**Files:**
- Modify: `Memgram/Database/Meeting.swift`

- [ ] **Replace the entire file with the updated model:**

```swift
import Foundation
import GRDB

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pendingUpload = "pending_upload"
    case placeholder
    case synced
    case failed
}

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording, transcribing, diarizing, done, interrupted, error
}

struct Meeting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetings"

    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var status: MeetingStatus
    var syncStatus: SyncStatus = .pendingUpload
    var summary: String?
    var actionItems: String?
    var rawTranscript: String?
    var ckSystemFields: Data?
    var calendarEventId: String?
    var calendarContext: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case startedAt       = "started_at"
        case endedAt         = "ended_at"
        case durationSeconds = "duration_seconds"
        case status
        case syncStatus      = "sync_status"
        case summary
        case actionItems     = "action_items"
        case rawTranscript   = "raw_transcript"
        case ckSystemFields  = "ck_system_fields"
        case calendarEventId = "calendar_event_id"
        case calendarContext = "calendar_context"
    }
}
```

- [ ] **Build to verify the model compiles (expect errors in files that use old MeetingStatus cases — that's expected, fixed in later tasks):**

```bash
cd /Users/jevgenikabanov/Documents/Projects/Claude/Memgram
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

Expected: errors referencing missing `MeetingStatus` cases in other files. No errors in `Meeting.swift` itself.

- [ ] **Commit:**

```bash
git add Memgram/Database/Meeting.swift
git commit -m "feat: add SyncStatus enum and expand MeetingStatus with diarizing/interrupted"
```

---

## Task 2: Schema migration + CloudKit state reset

**Files:**
- Modify: `Memgram/Database/AppDatabase.swift`
- Modify: `Memgram/AppDelegate.swift`

- [ ] **Add the v4 migration and `needsCloudResync` flag to AppDatabase.swift. Replace `runMigrations()` with:**

```swift
private(set) var needsCloudResync = false

private func runMigrations() throws {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("v1_initial_schema") { db in
        try db.create(table: "meetings") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("started_at", .double).notNull()
            t.column("ended_at", .double)
            t.column("duration_seconds", .double)
            t.column("status", .text).notNull().defaults(to: "recording")
            t.column("summary", .text)
            t.column("action_items", .text)
            t.column("raw_transcript", .text)
        }
        try db.create(table: "segments") { t in
            t.column("id", .text).primaryKey()
            t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("speaker", .text).notNull()
            t.column("channel", .text).notNull()
            t.column("start_seconds", .double).notNull()
            t.column("end_seconds", .double).notNull()
            t.column("text", .text).notNull()
        }
        try db.create(table: "speakers") { t in
            t.column("id", .text).primaryKey()
            t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("label", .text).notNull()
            t.column("custom_name", .text)
        }
        try db.create(table: "embeddings") { t in
            t.column("id", .text).primaryKey()
            t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("chunk_text", .text).notNull()
            t.column("embedding", .blob).notNull()
            t.column("model", .text).notNull()
        }
        try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
            t.tokenizer = .unicode61()
            t.content = "segments"
            t.contentRowID = "rowid"
            t.column("text")
            t.column("speaker")
        }
        try db.execute(sql: """
            CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                INSERT INTO segments_fts(rowid, text, speaker)
                VALUES (new.rowid, new.text, new.speaker);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                VALUES ('delete', old.rowid, old.text, old.speaker);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                VALUES ('delete', old.rowid, old.text, old.speaker);
                INSERT INTO segments_fts(rowid, text, speaker)
                VALUES (new.rowid, new.text, new.speaker);
            END
        """)
    }

    migrator.registerMigration("v2_cloudkit_sync") { db in
        try db.alter(table: "meetings") { t in t.add(column: "ck_system_fields", .blob) }
        try db.alter(table: "segments") { t in t.add(column: "ck_system_fields", .blob) }
        try db.alter(table: "speakers") { t in t.add(column: "ck_system_fields", .blob) }
    }

    migrator.registerMigration("v3_calendar_fields") { db in
        try db.alter(table: "meetings") { t in
            t.add(column: "calendar_event_id", .text)
            t.add(column: "calendar_context", .text)
        }
    }

    migrator.registerMigration("v4_semantic_status") { db in
        // Nuke all data — re-downloaded from CloudKit with correct schema.
        // The meetings table needs sync_status; MeetingStatus needs diarizing/interrupted.
        try db.execute(sql: "DROP TRIGGER IF EXISTS segments_au")
        try db.execute(sql: "DROP TRIGGER IF EXISTS segments_ad")
        try db.execute(sql: "DROP TRIGGER IF EXISTS segments_ai")
        try db.execute(sql: "DROP TABLE IF EXISTS segments_fts")
        try db.execute(sql: "DROP TABLE IF EXISTS embeddings")
        try db.execute(sql: "DROP TABLE IF EXISTS speakers")
        try db.execute(sql: "DROP TABLE IF EXISTS segments")
        try db.execute(sql: "DROP TABLE IF EXISTS meetings")

        try db.create(table: "meetings") { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("started_at", .double).notNull()
            t.column("ended_at", .double)
            t.column("duration_seconds", .double)
            t.column("status", .text).notNull().defaults(to: "done")
            t.column("sync_status", .text).notNull().defaults(to: "pending_upload")
            t.column("summary", .text)
            t.column("action_items", .text)
            t.column("raw_transcript", .text)
            t.column("ck_system_fields", .blob)
            t.column("calendar_event_id", .text)
            t.column("calendar_context", .text)
        }
        try db.create(table: "segments") { t in
            t.column("id", .text).primaryKey()
            t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("speaker", .text).notNull()
            t.column("channel", .text).notNull()
            t.column("start_seconds", .double).notNull()
            t.column("end_seconds", .double).notNull()
            t.column("text", .text).notNull()
            t.column("ck_system_fields", .blob)
        }
        try db.create(table: "speakers") { t in
            t.column("id", .text).primaryKey()
            t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("label", .text).notNull()
            t.column("custom_name", .text)
            t.column("ck_system_fields", .blob)
        }
        try db.create(table: "embeddings") { t in
            t.column("id", .text).primaryKey()
            t.column("meeting_id", .text).notNull().references("meetings", onDelete: .cascade)
            t.column("chunk_text", .text).notNull()
            t.column("embedding", .blob).notNull()
            t.column("model", .text).notNull()
        }
        try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
            t.tokenizer = .unicode61()
            t.content = "segments"
            t.contentRowID = "rowid"
            t.column("text")
            t.column("speaker")
        }
        try db.execute(sql: """
            CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                INSERT INTO segments_fts(rowid, text, speaker)
                VALUES (new.rowid, new.text, new.speaker);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                VALUES ('delete', old.rowid, old.text, old.speaker);
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                VALUES ('delete', old.rowid, old.text, old.speaker);
                INSERT INTO segments_fts(rowid, text, speaker)
                VALUES (new.rowid, new.text, new.speaker);
            END
        """)
    }

    // Detect if v4 was just applied so AppDelegate can clear CloudKit sync state
    let appliedBefore = Set((try? dbQueue.read { try migrator.appliedIdentifiers($0) }) ?? [])
    try migrator.migrate(dbQueue)
    let appliedAfter = Set((try? dbQueue.read { try migrator.appliedIdentifiers($0) }) ?? [])
    if appliedAfter.contains("v4_semantic_status") && !appliedBefore.contains("v4_semantic_status") {
        needsCloudResync = true
    }
}
```

- [ ] **In AppDelegate.swift, find the block where `CloudSyncEngine.shared.start()` is called (around line 59-64) and insert the reset check immediately before it:**

```swift
// Clear CloudKit sync state if the DB schema was just migrated to v4.
// The nuke migration wiped all local data; re-download everything from CloudKit.
if AppDatabase.shared.needsCloudResync {
    UserDefaults.standard.removeObject(forKey: "CKSyncEngineState")
    appLog.info("Cleared CloudKit sync state after v4 schema migration")
}
```

The full block should look like:
```swift
if #available(macOS 14.0, *) {
    if AppDatabase.shared.needsCloudResync {
        UserDefaults.standard.removeObject(forKey: "CKSyncEngineState")
        appLog.info("Cleared CloudKit sync state after v4 schema migration")
    }
    CloudSyncEngine.shared.start()
    appLog.info("CloudSync started")
    RemoteMeetingProcessor.shared.start()
    appLog.info("RemoteMeetingProcessor started")
}
```

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

Expected: no errors in the two files just modified. Errors about `MeetingStatus` in other files still expected.

- [ ] **Commit:**

```bash
git add Memgram/Database/AppDatabase.swift Memgram/AppDelegate.swift
git commit -m "feat: add v4_semantic_status migration (nuke+recreate) and post-migration CloudKit reset"
```

---

## Task 3: MeetingStore — update interruptedMeetings + add updateSyncStatus

**Files:**
- Modify: `Memgram/Database/MeetingStore.swift`

- [ ] **Update `interruptedMeetings()` to include `.diarizing`** (around line 239):

```swift
func interruptedMeetings() throws -> [Meeting] {
    try db.read { db in
        try Meeting
            .filter(Column("status") == MeetingStatus.recording.rawValue
                 || Column("status") == MeetingStatus.transcribing.rawValue
                 || Column("status") == MeetingStatus.diarizing.rawValue)
            .order(Column("started_at").desc)
            .fetchAll(db)
    }
}
```

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

- [ ] **Commit:**

```bash
git add Memgram/Database/MeetingStore.swift
git commit -m "feat: update interruptedMeetings for diarizing status, add updateSyncStatus"
```

---

## Task 4: CloudSyncEngine — published state + enqueueSave writes pendingUpload

**Files:**
- Modify: `Memgram/Sync/CloudSyncEngine.swift`

- [ ] **Add `ObservableObject` conformance and `@Published` state properties.** Find the class declaration (around line 1) and update:

```swift
@available(macOS 14.0, *)
final class CloudSyncEngine: ObservableObject {
    static let shared = CloudSyncEngine()
    // ... existing properties ...

    @Published var uploadingIds: Set<String> = []
    @Published var pendingCount: Int = 0
    @Published var failedCount: Int = 0
```

- [ ] **Add `refreshSyncCounts()` as a private helper method** (add after the `enqueueDelete` method, around line 143):

```swift
private func refreshSyncCounts() {
    do {
        let pending = try db.read { db in
            try Meeting
                .filter(Column("sync_status") == SyncStatus.pendingUpload.rawValue)
                .fetchCount(db)
        }
        let failed = try db.read { db in
            try Meeting
                .filter(Column("sync_status") == SyncStatus.failed.rawValue)
                .fetchCount(db)
        }
        DispatchQueue.main.async { [weak self] in
            self?.pendingCount = pending
            self?.failedCount = failed
        }
    } catch {
        logger.error("[CloudSync] Failed to refresh sync counts: \(error)")
    }
}
```

- [ ] **Update `enqueueSave` to also write `sync_status = .pendingUpload` for meetings:**

```swift
func enqueueSave(table: String, id: String) {
    guard let engine = syncEngine else { return }
    let recordID = makeRecordID(table: table, id: id)
    engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    guard table == "meetings" else { return }
    do {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET sync_status = ? WHERE id = ?",
                arguments: [SyncStatus.pendingUpload.rawValue, id]
            )
        }
        refreshSyncCounts()
    } catch {
        logger.error("[CloudSync] Failed to set pendingUpload for meeting \(id): \(error)")
    }
}
```

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

- [ ] **Commit:**

```bash
git add Memgram/Sync/CloudSyncEngine.swift
git commit -m "feat: add @Published sync state and enqueueSave writes pendingUpload to DB"
```

---

## Task 5: CloudSyncEngine — applyRemoteRecord sets synced + normalizes interrupted + placeholder status

**Files:**
- Modify: `Memgram/Sync/CloudSyncEngine.swift`

- [ ] **In `applyRemoteRecord`, update the meeting insert/update block** (around line 394-438). The key changes: (a) set `syncStatus: .synced` in the new meeting object; (b) normalize `interrupted`; (c) keep `syncStatus = .synced` on merge:

```swift
case "meetings":
    var meeting = Meeting(
        id: id,
        title: record["title"] as? String ?? "Untitled",
        startedAt: record["startedAt"] as? Date ?? Date(),
        endedAt: record["endedAt"] as? Date,
        durationSeconds: record["durationSeconds"] as? Double,
        status: MeetingStatus(rawValue: record["status"] as? String ?? "done") ?? .done,
        syncStatus: .synced,
        summary: record["summary"] as? String,
        actionItems: record["actionItems"] as? String,
        rawTranscript: record["rawTranscript"] as? String,
        ckSystemFields: systemFieldsData,
        calendarEventId: record["calendarEventId"] as? String,
        calendarContext: record["calendarContext"] as? String
    )
    // Normalize: CloudKit stores .done for meetings that ended without a transcript
    if meeting.status == .done && meeting.rawTranscript == nil {
        meeting.status = .interrupted
    }
    try db.write { db in
        if let existing = try Meeting.fetchOne(db, key: id) {
            var merged = meeting
            merged.ckSystemFields = systemFieldsData
            merged.syncStatus = .synced
            merged.summary = existing.summary ?? merged.summary
            merged.rawTranscript = existing.rawTranscript ?? merged.rawTranscript
            merged.actionItems = existing.actionItems ?? merged.actionItems
            if existing.ckSystemFields != nil {
                let statusOrder: [MeetingStatus] = [.recording, .transcribing, .diarizing, .done, .interrupted, .error]
                let existingRank = statusOrder.firstIndex(of: existing.status) ?? 0
                let remoteRank  = statusOrder.firstIndex(of: meeting.status)  ?? 0
                if existingRank > remoteRank { merged.status = existing.status }
            }
            try merged.update(db)
        } else {
            try meeting.insert(db)
        }
    }
```

- [ ] **Update placeholder creation in the `segments` case** (around line 456-463) to set `syncStatus: .placeholder`:

```swift
let placeholder = Meeting(
    id: meetingId, title: "Syncing…", startedAt: Date(),
    endedAt: nil, durationSeconds: nil, status: .done,
    syncStatus: .placeholder,
    summary: nil, actionItems: nil, rawTranscript: nil,
    ckSystemFields: nil
)
```

- [ ] **Do the same for the placeholder in the `speakers` case** (around line 486-492):

```swift
let placeholder = Meeting(
    id: meetingId, title: "Syncing…", startedAt: Date(),
    endedAt: nil, durationSeconds: nil, status: .done,
    syncStatus: .placeholder,
    summary: nil, actionItems: nil, rawTranscript: nil,
    ckSystemFields: nil
)
```

- [ ] **Call `refreshSyncCounts()` in the `fetchedRecordZoneChanges` batch handler**, just before the existing `meetingDidUpdate` post (around line 631):

```swift
if totalChanges > 0 {
    engine.refreshSyncCounts()
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
    }
}
```

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

- [ ] **Commit:**

```bash
git add Memgram/Sync/CloudSyncEngine.swift
git commit -m "feat: applyRemoteRecord sets synced, normalizes interrupted, placeholders get .placeholder"
```

---

## Task 6: CloudSyncEngine — uploadingIds tracking + updateSystemFields sets synced + error handling

**Files:**
- Modify: `Memgram/Sync/CloudSyncEngine.swift`

- [ ] **Update `nextRecordZoneChangeBatch` to add meeting IDs to `uploadingIds` before sending** (replace the existing function around line 703):

```swift
func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
) async -> CKSyncEngine.RecordZoneChangeBatch? {
    let scope = context.options.scope
    let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
    guard !pendingChanges.isEmpty else { return nil }

    // Mark meetings as in-flight before the batch is sent
    let meetingIds = pendingChanges.compactMap { change -> String? in
        guard case .saveRecord(let recordID) = change,
              let parsed = self.engine.parseRecordID(recordID),
              parsed.table == "meetings" else { return nil }
        return parsed.id
    }
    if !meetingIds.isEmpty {
        DispatchQueue.main.async {
            meetingIds.forEach { self.engine.uploadingIds.insert($0) }
        }
    }

    return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
        guard let parsed = self.engine.parseRecordID(recordID) else { return nil }
        return self.engine.buildRecord(table: parsed.table, id: parsed.id)
    }
}
```

- [ ] **Update `updateSystemFields` to also set `sync_status = .synced` and remove from `uploadingIds` for meetings:**

```swift
fileprivate func updateSystemFields(for record: CKRecord) {
    guard let parsed = parseRecordID(record.recordID) else { return }
    let (table, id) = parsed
    let data = encodeSystemFields(record)

    do {
        switch table {
        case "meetings":
            try db.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET ck_system_fields = ?, sync_status = ? WHERE id = ?",
                    arguments: [data, SyncStatus.synced.rawValue, id]
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.uploadingIds.remove(id)
            }
            refreshSyncCounts()
        case "segments":
            try db.write { db in
                try db.execute(
                    sql: "UPDATE segments SET ck_system_fields = ? WHERE id = ?",
                    arguments: [data, id]
                )
            }
        case "speakers":
            try db.write { db in
                try db.execute(
                    sql: "UPDATE speakers SET ck_system_fields = ? WHERE id = ?",
                    arguments: [data, id]
                )
            }
        default:
            break
        }
    } catch {
        logger.error("Failed to update system fields for \(table)/\(id): \(error)")
    }
}
```

- [ ] **Update the `unknownItem` error handler** (around line 671) to set `sync_status = .failed` and remove from `uploadingIds`:

```swift
case .unknownItem:
    engine.logger.warning("[CloudSync] Unknown item — treating as remote deletion: \(recordID.recordName)")
    engine.applyRemoteDeletion(recordID)
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
    }
```

Note: `unknownItem` means the record doesn't exist on the server — treated as deletion, which is correct. The meeting is deleted locally, so no sync_status update needed.

- [ ] **Update the default error case** (around line 684) to set `.failed` for meeting saves:

```swift
default:
    engine.logger.error("Record save failed (\(ckError.code.rawValue)): \(ckError.localizedDescription)")
    if let parsed = engine.parseRecordID(recordID), parsed.table == "meetings" {
        do {
            try engine.db.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET sync_status = ? WHERE id = ?",
                    arguments: [SyncStatus.failed.rawValue, parsed.id]
                )
            }
            DispatchQueue.main.async { engine.uploadingIds.remove(parsed.id) }
            engine.refreshSyncCounts()
        } catch {
            engine.logger.error("Failed to set .failed for meeting \(parsed.id): \(error)")
        }
    }
```

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

- [ ] **Commit:**

```bash
git add Memgram/Sync/CloudSyncEngine.swift
git commit -m "feat: uploadingIds tracking, updateSystemFields sets synced, errors set failed"
```

---

## Task 7: CloudSyncEngine — simplify queries + remove reconcileAfterReset

**Files:**
- Modify: `Memgram/Sync/CloudSyncEngine.swift`

- [ ] **Replace `reEnqueueOrphanedRecords`** with the simpler `sync_status`-based query:

```swift
fileprivate func reEnqueueOrphanedRecords() {
    do {
        let orphans: [Meeting] = try db.read { db in
            try Meeting
                .filter(Column("sync_status") == SyncStatus.pendingUpload.rawValue)
                .fetchAll(db)
        }
        guard !orphans.isEmpty else { return }
        logger.info("[CloudSync] Re-enqueuing \(orphans.count) orphaned local records")
        for meeting in orphans {
            enqueueSave(table: "meetings", id: meeting.id)
            enqueueSaveSegments(meetingId: meeting.id)
        }
    } catch {
        logger.error("[CloudSync] Failed to re-enqueue orphaned records: \(error)")
    }
}
```

- [ ] **Replace `auditStalePlaceholders`** with the simpler `sync_status`-based query:

```swift
fileprivate func auditStalePlaceholders() {
    do {
        let cutoff = Date().addingTimeInterval(-300)
        let stale: [Meeting] = try db.read { db in
            try Meeting
                .filter(Column("sync_status") == SyncStatus.placeholder.rawValue)
                .filter(Column("started_at") < cutoff)
                .fetchAll(db)
        }
        guard !stale.isEmpty else { return }
        logger.warning("[CloudSync] Found \(stale.count) stale placeholder(s) — triggering fetch")
        Task { await self.fetchNow() }
    } catch {
        logger.error("[CloudSync] Placeholder audit failed: \(error)")
    }
}
```

- [ ] **Delete `reconcileAfterReset` entirely** (lines ~232-258). Remove the method body and its call in the `start()` Task block. The `start()` Task should become:

```swift
Task {
    do {
        logger.info("[CloudSync] Fetching changes...")
        try await engine.fetchChanges()
        logger.info("[CloudSync] Fetch complete")
        engine.auditStalePlaceholders()
    } catch {
        logger.error("[CloudSync] Fetch failed: \(error)")
    }
}
```

- [ ] **Delete the `isResetting` and `fetchedDuringReset` properties** (lines 22-23) and all references to them:
  - Remove `nonisolated(unsafe) private var isResetting = false`
  - Remove `nonisolated(unsafe) private var fetchedDuringReset: Set<String> = []`
  - Remove the `isResetting = true` and `fetchedDuringReset = []` lines in `resetAndResync()`
  - Remove the `if isResetting && table == "meetings" { fetchedDuringReset.insert(id) }` block in `applyRemoteRecord` (around line 385)

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

Expected: clean build for CloudSyncEngine.

- [ ] **Commit:**

```bash
git add Memgram/Sync/CloudSyncEngine.swift
git commit -m "refactor: simplify CloudSyncEngine queries using sync_status, remove reconcileAfterReset"
```

---

## Task 8: Recording pipeline — diarizing status + interrupted recovery

**Files:**
- Modify: `Memgram/Audio/RecordingSession.swift`

- [ ] **Replace the diarization block** (lines 218-239) to write `.diarizing`/`.done` to the DB instead of using the in-memory `diarizingMeetingId`:

```swift
#if os(macOS)
if #available(macOS 14.0, *) {
    try? MeetingStore.shared.updateStatus(id, status: .diarizing)
    NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
    let labelMap = await self.speakerDiarizer.runAndResolve(segments: self.segments)
    try? MeetingStore.shared.updateStatus(id, status: .done)
    if !labelMap.isEmpty {
        for i in self.segments.indices {
            if let label = labelMap[self.segments[i].id.uuidString] {
                self.segments[i].speaker = label
            }
        }
        for segment in self.segments {
            if let label = labelMap[segment.id.uuidString] {
                try? MeetingStore.shared.updateSegmentSpeaker(
                    id: segment.id.uuidString, speaker: label)
            }
        }
        self.log.info("Diarization complete — updated \(labelMap.count) segment labels")
        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
    }
}
#endif
```

- [ ] **Remove the `diarizingMeetingId` published property** (line 20-21):
  - Delete: `@Published private(set) var diarizingMeetingId: String?`
  - Delete any reads of `diarizingMeetingId` elsewhere in RecordingSession or other files — replace them with DB status checks if needed. Search with:

```bash
grep -rn "diarizingMeetingId" /Users/jevgenikabanov/Documents/Projects/Claude/Memgram --include="*.swift"
```

For each occurrence in UI files, replace the check with `meeting.status == .diarizing`.

- [ ] **Update `recoverMeeting` to set `.interrupted` instead of `.done`** (line 83):

```swift
func recoverMeeting(_ meeting: Meeting) {
    do { try MeetingStore.shared.updateStatus(meeting.id, status: .interrupted) }
    catch { log.error("updateStatus(.interrupted) failed for meeting \(meeting.id, privacy: .public): \(error)") }
    interruptedMeetings.removeAll { $0.id == meeting.id }
}
```

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "^.*error:" | head -20
```

- [ ] **Commit:**

```bash
git add Memgram/Audio/RecordingSession.swift
git commit -m "feat: replace diarizingMeetingId with DB .diarizing status, recoverMeeting sets .interrupted"
```

---

## Task 9: Mac UI — MeetingListView filter + row + global header

**Files:**
- Modify: `Memgram/UI/MainWindow/MeetingListView.swift`

- [ ] **Replace the `load()` filter** with the single-condition version:

```swift
private func load() {
    let all = (try? MeetingStore.shared.fetchAll()) ?? []
    meetings = all.filter { $0.syncStatus != .placeholder }
}
```

- [ ] **Replace `MeetingRowView`** entirely with the new version using clean switches and a cloud icon:

```swift
private struct MeetingRowView: View {
    let meeting: Meeting
    @ObservedObject private var summaryEngine = SummaryEngine.shared
    @ObservedObject private var syncEngine    = CloudSyncEngine.shared

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if meeting.summary != nil {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CloudSyncIcon(meeting: meeting)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch meeting.status {
        case .recording:                return .red
        case .transcribing, .diarizing: return .orange
        case .done:                     return .green
        case .interrupted:              return .secondary
        case .error:                    return Color.red.opacity(0.5)
        }
    }

    private var subtitle: String {
        let time = DateFormatter.localizedString(from: meeting.startedAt,
                                                  dateStyle: .none, timeStyle: .short)
        switch meeting.status {
        case .recording:    return "\(time) · Recording…"
        case .transcribing: return "\(time) · Transcribing…"
        case .diarizing:    return "\(time) · Identifying speakers…"
        case .interrupted:  return "\(time) · Interrupted"
        case .error:        return "\(time) · Error"
        case .done:
            if summaryEngine.activeMeetingIds.contains(meeting.id) { return "\(time) · Summarising…" }
            guard let dur = meeting.durationSeconds else { return time }
            let mins = Int(dur / 60)
            return mins > 0 ? "\(time) · \(mins)m" : time
        }
    }
}
```

- [ ] **Add `CloudSyncIcon` view** (add before `MeetingRowView`):

```swift
private struct CloudSyncIcon: View {
    let meeting: Meeting
    @ObservedObject private var syncEngine = CloudSyncEngine.shared
    @State private var pulse = false

    var body: some View {
        Group {
            switch meeting.syncStatus {
            case .synced:
                Image(systemName: "icloud.fill")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(.red)
            case .pendingUpload:
                if syncEngine.uploadingIds.contains(meeting.id) {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .foregroundStyle(.secondary)
                        .opacity(pulse ? 0.4 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                } else {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            case .placeholder:
                EmptyView()
            }
        }
        .font(.caption)
    }
}
```

- [ ] **Add `SyncStatusHeader` view** (add after `CloudSyncIcon`):

```swift
private struct SyncStatusHeader: View {
    @ObservedObject private var syncEngine = CloudSyncEngine.shared

    var body: some View {
        if syncEngine.pendingCount > 0 || syncEngine.failedCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if syncEngine.failedCount > 0 {
                    Label(
                        "\(syncEngine.failedCount) meeting\(syncEngine.failedCount == 1 ? "" : "s") failed to sync",
                        systemImage: "exclamationmark.icloud"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                if syncEngine.pendingCount > 0 {
                    Label(
                        "Syncing \(syncEngine.pendingCount) meeting\(syncEngine.pendingCount == 1 ? "" : "s")…",
                        systemImage: "icloud.and.arrow.up"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}
```

- [ ] **Insert `SyncStatusHeader` above the `List` in `MeetingListView.body`:**

```swift
var body: some View {
    VStack(spacing: 0) {
        SyncStatusHeader()
        List(selection: $selectedMeetingId) {
            // ... existing content unchanged ...
        }
    }
    .navigationTitle("Meetings")
    .onAppear { load() }
    .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in load() }
    // ... existing alerts unchanged ...
}
```

- [ ] **Build:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Commit:**

```bash
git add Memgram/UI/MainWindow/MeetingListView.swift
git commit -m "feat: Mac meeting list — simplified filter, cloud icons, global sync header"
```

---

## Task 10: iOS — MobileMeetingListView filter + cloud icon + banner + StatusBadge

**Files:**
- Modify: `MemgramMobile/UI/MobileMeetingListView.swift`

- [ ] **Replace `loadMeetings()` filter:**

```swift
private func loadMeetings() {
    let all = (try? MeetingStore.shared.fetchAll()) ?? []
    meetings = all.filter { $0.syncStatus != .placeholder }
    log.debug("Loaded \(self.meetings.count) meetings (filtered from \(all.count) total)")
}
```

- [ ] **Add `CloudSyncIcon` view for iOS** (add before `MeetingRow`):

```swift
private struct CloudSyncIcon: View {
    let meeting: Meeting
    @ObservedObject private var syncEngine = CloudSyncEngine.shared
    @State private var pulse = false

    var body: some View {
        Group {
            switch meeting.syncStatus {
            case .synced:
                Image(systemName: "icloud.fill").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.red)
            case .pendingUpload:
                if syncEngine.uploadingIds.contains(meeting.id) {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .foregroundStyle(.secondary)
                        .opacity(pulse ? 0.4 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                } else {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
                }
            case .placeholder:
                EmptyView()
            }
        }
        .font(.caption2)
    }
}
```

- [ ] **Update `MeetingRow` to add the cloud icon** (in the `HStack` after `StatusBadge`):

```swift
private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                CloudSyncIcon(meeting: meeting)
                StatusBadge(status: meeting.status)
            }
            HStack(spacing: 6) {
                Text(DateFormatter.localizedString(from: meeting.startedAt,
                                                   dateStyle: .none, timeStyle: .short))
                if let dur = meeting.durationSeconds, dur > 0 {
                    Text("·")
                    Text(formatDuration(dur))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
```

- [ ] **Update `StatusBadge` to handle new `MeetingStatus` cases:**

```swift
private struct StatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        switch status {
        case .recording:
            Label("Recording", systemImage: "mic.fill")
                .font(.caption2).foregroundStyle(.red)
        case .transcribing, .diarizing:
            Label("Processing", systemImage: "hourglass")
                .font(.caption2).foregroundStyle(.orange)
        case .interrupted:
            Label("Interrupted", systemImage: "exclamationmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .done:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
        }
    }
}
```

- [ ] **Add `SyncStatusBanner` and insert it in `MobileMeetingListView.body`** above the `List`:

```swift
private struct SyncStatusBanner: View {
    @ObservedObject private var syncEngine = CloudSyncEngine.shared

    var body: some View {
        if syncEngine.pendingCount > 0 || syncEngine.failedCount > 0 {
            VStack(alignment: .leading, spacing: 2) {
                if syncEngine.failedCount > 0 {
                    Label("\(syncEngine.failedCount) meeting\(syncEngine.failedCount == 1 ? "" : "s") failed to sync",
                          systemImage: "exclamationmark.icloud")
                        .font(.caption).foregroundStyle(.red)
                }
                if syncEngine.pendingCount > 0 {
                    Label("Syncing \(syncEngine.pendingCount) meeting\(syncEngine.pendingCount == 1 ? "" : "s")…",
                          systemImage: "icloud.and.arrow.up")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
        }
    }
}
```

Insert in `MobileMeetingListView.body` — wrap the `List` in a `VStack`:

```swift
var body: some View {
    NavigationStack {
        VStack(spacing: 0) {
            SyncStatusBanner()
            List {
                // ... existing content unchanged ...
            }
        }
        .navigationTitle("Meetings")
        // ... existing modifiers unchanged ...
    }
}
```

- [ ] **Build for iOS target:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD" | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Build Mac target too for final verification:**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD" | tail -5
```

Expected: `BUILD SUCCEEDED`

- [ ] **Commit:**

```bash
git add MemgramMobile/UI/MobileMeetingListView.swift
git commit -m "feat: iOS meeting list — simplified filter, cloud icons, sync banner, StatusBadge new cases"
```

---

## Post-implementation checklist

- [ ] Launch app from Xcode on a device with existing CloudKit data — verify meeting list shows cloud icons correctly
- [ ] Record a new meeting — verify row shows `icloud.and.arrow.up` (pending) then `icloud.fill` (synced) after CloudKit ack
- [ ] Check Settings → Sync → Re-sync from iCloud — verify meetings re-appear with `icloud.fill` icons
- [ ] Verify interrupted meetings (from `loadInterruptedMeetings`) show grey dot + "Interrupted" subtitle
- [ ] Verify "Identifying speakers…" subtitle appears while diarization runs (status `.diarizing`)
