# Sync Logging Instrumentation + Global Privacy Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all app logs readable in Console.app and BugReport submissions, and add six missing CloudKit sync lifecycle log points for cross-device debugging.

**Architecture:** Introduce a `PublicLogger` wrapper returned by `Logger.make()` that evaluates log messages as plain `String` then re-logs with `privacy: .public`. Strip the now-redundant `privacy: .public` annotations from call sites. Migrate the two sync files and three Watch files from direct `Logger(subsystem:category:)` construction to `Logger.make()`. Add six missing log points to the sync lifecycle.

**Tech Stack:** OSLog (`import os`), Swift `@autoclosure`, `xcodebuild`

---

## File Map

| File | Change |
|---|---|
| `Memgram/Utilities/Log.swift` | Replace with `PublicLogger` + updated `Logger.make()` |
| `MemgramWatch/Log.swift` | Create — duplicate of above for Watch target (no shared utilities) |
| `Memgram/Sync/CloudSyncEngine.swift` | Migrate logger; add log points 1, 2, 4, 5, 6 |
| `Memgram/Sync/CKSyncTransport.swift` | Migrate logger; add log point 3 |
| `MemgramWatch/WatchAudioRecorder.swift` | Migrate logger to `Logger.make()` |
| `MemgramWatch/WatchRecordingView.swift` | Migrate logger to `Logger.make()` |
| `MemgramWatch/WatchSessionManager.swift` | Migrate logger to `Logger.make()` |
| All `Memgram/` + `MemgramMobile/` Swift files | Strip `, privacy: .public` (becomes redundant) |

---

### Task 1: Replace `Log.swift` with `PublicLogger`

**Files:**
- Modify: `Memgram/Utilities/Log.swift`

- [ ] **Step 1: Replace the file contents**

```swift
import OSLog

struct PublicLogger {
    private let logger: Logger

    func info(_ message: @autoclosure () -> String)     { let m = message(); logger.info("\(m, privacy: .public)") }
    func error(_ message: @autoclosure () -> String)    { let m = message(); logger.error("\(m, privacy: .public)") }
    func warning(_ message: @autoclosure () -> String)  { let m = message(); logger.warning("\(m, privacy: .public)") }
    func debug(_ message: @autoclosure () -> String)    { let m = message(); logger.debug("\(m, privacy: .public)") }
    func fault(_ message: @autoclosure () -> String)    { let m = message(); logger.fault("\(m, privacy: .public)") }
    func notice(_ message: @autoclosure () -> String)   { let m = message(); logger.notice("\(m, privacy: .public)") }
    func critical(_ message: @autoclosure () -> String) { let m = message(); logger.critical("\(m, privacy: .public)") }
}

extension Logger {
    static func make(_ category: String) -> PublicLogger {
        PublicLogger(logger: Logger(subsystem: "com.memgram.app", category: category))
    }
}
```

- [ ] **Step 2: Strip all `privacy: .public` annotations from Memgram and Mobile Swift files**

These are now redundant — `PublicLogger` handles it at the logger level. The annotations used OSLog-specific string interpolation syntax (`OSLogMessage`) that is incompatible with `@autoclosure () -> String`.

```bash
find Memgram/ MemgramMobile/ -name "*.swift" -exec sed -i '' 's/, privacy: \.public//g' {} \;
```

Verify the strip worked and nothing unexpected changed:
```bash
grep -rn "privacy: .public" Memgram/ MemgramMobile/ --include="*.swift"
```
Expected: no output (zero matches).

- [ ] **Step 3: Verify build passes for main and mobile targets**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Utilities/Log.swift
git add $(git diff --name-only Memgram/ MemgramMobile/)
git commit -m "refactor: introduce PublicLogger — all log output now visible in Console.app"
```

---

### Task 2: Add `Log.swift` to Watch target and migrate Watch loggers

**Files:**
- Create: `MemgramWatch/Log.swift`
- Modify: `MemgramWatch/WatchAudioRecorder.swift`
- Modify: `MemgramWatch/WatchRecordingView.swift`
- Modify: `MemgramWatch/WatchSessionManager.swift`

Watch target sources are under `path: MemgramWatch` in `project.yml`, so a new file there is automatically included.

- [ ] **Step 1: Create `MemgramWatch/Log.swift`**

Exact duplicate of the `Memgram/Utilities/Log.swift` written in Task 1 (Watch target doesn't include `Memgram/Utilities`):

```swift
import OSLog

struct PublicLogger {
    private let logger: Logger

    func info(_ message: @autoclosure () -> String)     { let m = message(); logger.info("\(m, privacy: .public)") }
    func error(_ message: @autoclosure () -> String)    { let m = message(); logger.error("\(m, privacy: .public)") }
    func warning(_ message: @autoclosure () -> String)  { let m = message(); logger.warning("\(m, privacy: .public)") }
    func debug(_ message: @autoclosure () -> String)    { let m = message(); logger.debug("\(m, privacy: .public)") }
    func fault(_ message: @autoclosure () -> String)    { let m = message(); logger.fault("\(m, privacy: .public)") }
    func notice(_ message: @autoclosure () -> String)   { let m = message(); logger.notice("\(m, privacy: .public)") }
    func critical(_ message: @autoclosure () -> String) { let m = message(); logger.critical("\(m, privacy: .public)") }
}

extension Logger {
    static func make(_ category: String) -> PublicLogger {
        PublicLogger(logger: Logger(subsystem: "com.memgram.app", category: category))
    }
}
```

- [ ] **Step 2: Run xcodegen to pick up the new file**

```bash
xcodegen generate
```

- [ ] **Step 3: Migrate `WatchAudioRecorder.swift`**

Change line 5:
```swift
// Before:
private let log = Logger(subsystem: "com.memgram.app", category: "WatchRecording")

// After:
private let log = Logger.make("WatchRecording")
```

- [ ] **Step 4: Migrate `WatchRecordingView.swift`**

Change line 4:
```swift
// Before:
private let log = Logger(subsystem: "com.memgram.app", category: "WatchUI")

// After:
private let log = Logger.make("WatchUI")
```

- [ ] **Step 5: Migrate `WatchSessionManager.swift`**

Change line 5:
```swift
// Before:
private let log = Logger(subsystem: "com.memgram.app", category: "WatchSession")

// After:
private let log = Logger.make("WatchSession")
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add MemgramWatch/Log.swift MemgramWatch/WatchAudioRecorder.swift \
  MemgramWatch/WatchRecordingView.swift MemgramWatch/WatchSessionManager.swift
git commit -m "refactor: migrate Watch loggers to PublicLogger via Logger.make()"
```

---

### Task 3: Migrate sync files to `Logger.make()`

**Files:**
- Modify: `Memgram/Sync/CloudSyncEngine.swift`
- Modify: `Memgram/Sync/CKSyncTransport.swift`

- [ ] **Step 1: Migrate `CloudSyncEngine.swift`**

Change line 16:
```swift
// Before:
fileprivate let logger = Logger(subsystem: "com.memgram.app", category: "CloudSync")

// After:
fileprivate let logger = Logger.make("CloudSync")
```

- [ ] **Step 2: Migrate `CKSyncTransport.swift`**

Change line 13:
```swift
// Before:
private let logger = Logger(subsystem: "com.memgram.app", category: "CKSyncTransport")

// After:
private let logger = Logger.make("CKSyncTransport")
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Sync/CloudSyncEngine.swift Memgram/Sync/CKSyncTransport.swift
git commit -m "refactor: migrate sync loggers to PublicLogger"
```

---

### Task 4: Add missing log points — `CloudSyncEngine.swift`

**Files:**
- Modify: `Memgram/Sync/CloudSyncEngine.swift`

Five points: enqueue entry, build success, upload confirmed, upload failed (all branches), meeting apply result.

- [ ] **Step 1: Point 1 — log on successful enqueue**

In `enqueueSave(table:id:)`, after line `transport.enqueueSave(recordID)`:

```swift
        guard let transport else { return }
        let recordID = makeRecordID(table: table, id: id)
        transport.enqueueSave(recordID)
        logger.info("[CloudSync] Enqueued \(table)/\(id) for upload")  // ADD THIS
    }
```

- [ ] **Step 2: Point 2 — log on successful record build**

In `buildCKRecord(table:id:)`, add a log before each `return record` in the three switch cases:

In the `"meetings"` case, before `return record`:
```swift
                logger.info("[CloudSync] Built record meetings/\(id) (\(meeting.ckSystemFields != nil ? "has systemFields" : "new"))")
                return record
```

In the `"segments"` case, before `return record`:
```swift
                logger.info("[CloudSync] Built record segments/\(id)")
                return record
```

In the `"speakers"` case, before `return record`:
```swift
                logger.info("[CloudSync] Built record speakers/\(id)")
                return record
```

- [ ] **Step 3: Point 4 — log each successfully uploaded record**

In `didSend(saved:failed:)`, replace:
```swift
        for savedRecord in saved {
            updateSystemFields(for: savedRecord)
        }
```
with:
```swift
        for savedRecord in saved {
            if let parsed = parseRecordID(savedRecord.recordID) {
                logger.info("[CloudSync] Uploaded \(parsed.table)/\(parsed.id) successfully")
            }
            updateSystemFields(for: savedRecord)
        }
```

- [ ] **Step 4: Point 5 — add meeting ID to all failure branches**

In `didSend`, the `switch ckError.code` block currently logs the ID only in `default`. Add the record name to every branch.

In `case .serverRecordChanged:`, add at the top of the case before the `if let serverRecord` check:
```swift
            case .serverRecordChanged:
                logger.warning("[CloudSync] Upload conflict for \(recordID.recordName) — applying server version")
                if let serverRecord = ckError.serverRecord {
```

In `case .zoneNotFound:`, replace the existing warning:
```swift
            case .zoneNotFound:
                logger.warning("[CloudSync] Upload failed for \(recordID.recordName) — zone not found, recreating")
                transport?.ensureZone(zoneID)
                transport?.enqueueSave(recordID)
```

In `default:`, replace the existing error log with one that includes the record name:
```swift
            default:
                logger.error("[CloudSync] Upload failed for \(recordID.recordName) — code \(ckError.code.rawValue): \(ckError.localizedDescription)")
                if let parsed = parseRecordID(recordID), parsed.table == "meetings" {
```

- [ ] **Step 5: Point 6 — log meeting apply result**

In `applyRemoteRecord`, the `"meetings"` case does a `db.write` that either inserts or updates. Add a `wasInsert` flag before the write and a log after it:

```swift
            case "meetings":
                // ... existing meeting construction and normalization code ...

                var wasInsert = false   // ADD THIS before db.write
                try db.write { db in
                    if let existing = try Meeting.fetchOne(db, key: id) {
                        var merged = meeting
                        // ... existing merge logic ...
                        try merged.update(db)
                    } else {
                        wasInsert = true   // ADD THIS
                        try meeting.insert(db)
                    }
                }
                logger.info("[CloudSync] Applied meeting \(id) — \(wasInsert ? "inserted" : "updated") — status \(meeting.status.rawValue)")  // ADD THIS
```

Note: `meeting.status` reflects the final normalized status because normalization happens before the `db.write` block.

- [ ] **Step 6: Build and run tests**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "passed|failed|error"
```
Expected: all tests pass (logging changes don't affect test behaviour).

- [ ] **Step 7: Commit**

```bash
git add Memgram/Sync/CloudSyncEngine.swift
git commit -m "feat: add sync lifecycle log points (enqueue, build, upload, apply)"
```

---

### Task 5: Add missing log point — `CKSyncTransport.swift`

**Files:**
- Modify: `Memgram/Sync/CKSyncTransport.swift`

- [ ] **Step 1: Point 3 — log batch size before sending**

In `nextRecordZoneChangeBatch`, add a log after the guard and before the `return await`:

```swift
    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pendingChanges.isEmpty else { return nil }

        logger.info("[CKSyncTransport] Sending batch of \(pendingChanges.count) records")  // ADD THIS

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit and push**

```bash
git add Memgram/Sync/CKSyncTransport.swift
git commit -m "feat: log batch size in CKSyncTransport before sending to CloudKit"
git push origin main
```

---

## Verification

Open Console.app on both devices. Filter:
- **Subsystem:** `com.memgram.app`
- **Category:** `CloudSync` (or `CKSyncTransport`)

Trigger a sync event (record a short meeting, or force-resync). You should now see fully readable log entries like:

```
[CloudSync] Enqueued meetings/ABC-123 for upload
[CloudSync] Built record meetings/ABC-123 (new)
[CKSyncTransport] Sending batch of 1 records
[CloudSync] Uploaded meetings/ABC-123 successfully
[CloudSync] Applied meeting ABC-123 — inserted — status done
```

If any step in this chain is missing on the receiving device, that's where the bug is.
