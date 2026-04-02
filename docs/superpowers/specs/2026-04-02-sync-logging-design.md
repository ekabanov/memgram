# Sync Logging Instrumentation + Global Privacy Fix

**Date:** 2026-04-02  
**Status:** Approved  
**Goal:** Make all app logs fully readable in Console.app and BugReport submissions, and make CloudKit sync fully observable for cross-device debugging.

---

## Problem

1. Every dynamic value in every log call across the app shows as `<private>` in Console.app and in BugReport submissions. OSLog redacts string interpolations by default unless explicitly marked `.public`. This affects all 32 files that use `log.*` or `logger.*`.
2. Sync-specific gaps: six key lifecycle events in CloudKit upload/download have no log entries at all, so even with privacy fixed you can't trace why a meeting didn't sync.

---

## Approach

Two complementary changes:

**1. Global privacy fix via `PublicLogger` wrapper** — change `Logger.make()` to return a thin `PublicLogger` struct whose methods accept `@autoclosure () -> String`. Interpolations evaluate to a plain `String` first, then log with `privacy: .public`. No call sites change — `log.info("got \(value)")` keeps working as-is. The 30 files using `Logger.make()` get the fix for free. The two sync files (`CloudSyncEngine`, `CKSyncTransport`) that construct `Logger` directly are migrated to use `Logger.make()`.

**2. Six missing sync log points** — added to `CloudSyncEngine.swift` and `CKSyncTransport.swift` covering the full upload/download lifecycle.

---

## Privacy Fix: `PublicLogger`

`Log.swift` is rewritten to define a `PublicLogger` struct and change `Logger.make()` to return it:

```swift
struct PublicLogger {
    private let logger: Logger

    func info(_ message: @autoclosure () -> String)    { let m = message(); logger.info("\(m, privacy: .public)") }
    func error(_ message: @autoclosure () -> String)   { let m = message(); logger.error("\(m, privacy: .public)") }
    func warning(_ message: @autoclosure () -> String) { let m = message(); logger.warning("\(m, privacy: .public)") }
    func debug(_ message: @autoclosure () -> String)   { let m = message(); logger.debug("\(m, privacy: .public)") }
    func fault(_ message: @autoclosure () -> String)   { let m = message(); logger.fault("\(m, privacy: .public)") }
}

extension Logger {
    static func make(_ category: String) -> PublicLogger {
        PublicLogger(logger: Logger(subsystem: "com.memgram.app", category: category))
    }
}
```

**Trade-off accepted:** OSLog's specialized per-type formatting (e.g., `%{public}d`) is lost. Since all values are being made public anyway, this doesn't matter. The string evaluated by `@autoclosure` is standard Swift interpolation — identical to what the original call sites produce.

**Migration:** `CloudSyncEngine` and `CKSyncTransport` currently create `Logger(subsystem:category:)` directly, bypassing `Logger.make()`. Both are updated to use `Logger.make("CloudSync")` and `Logger.make("CKSyncTransport")` respectively, and their `logger`/`log` properties change type from `Logger` to `PublicLogger`. All existing call sites in those files remain unchanged.

---

## Missing Sync Instrumentation Points

Six log calls added to complete the upload/download chain:

### 1. `enqueueSave(table:id:)` — entry
```
[CloudSync] Enqueued <table>/<id> for upload
```
Confirms the DB write triggered sync. Currently only logs on error.

### 2. `buildCKRecord(table:id:)` — success path
```
[CloudSync] Built record <table>/<id> (new | has systemFields)
```
Confirms the CKRecord was constructed. Currently only logs on error or unknown table.

### 3. `nextRecordZoneChangeBatch` — batch summary (`CKSyncTransport`)
```
[CKSyncTransport] Sending batch of N records
```
Confirms CKSyncEngine is requesting records to send. If this never fires, the engine isn't triggering uploads.

### 4. `didSend` — per saved record
```
[CloudSync] Uploaded <table>/<id> successfully
```
Confirms CloudKit acknowledged the record. Currently silent on success.

### 5. `didSend` — per failed record with error code (all branches)
```
[CloudSync] Upload failed for <table>/<id> — code N: <description>
```
Currently `.serverRecordChanged`, `.zoneNotFound`, `.unknownItem` log warnings without the meeting ID. This adds consistent ID + error code logging to all branches.

### 6. `applyRemoteRecord` — meeting insert vs update + final status
```
[CloudSync] Applied meeting <id> — inserted|updated — status <finalStatus>
```
Confirms what the receiving device stored. Currently meeting apply has no success log (only segments do).

---

## What This Enables in Console.app

Filter by subsystem `com.memgram.app`. For sync specifically, filter by category `CloudSync` or `CKSyncTransport` and correlate across devices:

| Question | Log point |
|---|---|
| Did device A enqueue the meeting? | Point 1 |
| Did CKSyncEngine build the record? | Point 2 |
| Did the engine attempt to send it? | Point 3 |
| Did CloudKit confirm receipt? | Point 4 |
| Why did upload fail? | Point 5 |
| Did device B receive and store it? | Point 6 |

For BugReport: log entries collected via `OSLogStore` will now contain actual values instead of `<private>` placeholders.

---

## Files Changed

| File | Change |
|---|---|
| `Memgram/Utilities/Log.swift` | Add `PublicLogger`; change `Logger.make()` return type |
| `Memgram/Sync/CloudSyncEngine.swift` | Migrate to `Logger.make()`; add points 1, 2, 4, 5, 6 |
| `Memgram/Sync/CKSyncTransport.swift` | Migrate to `Logger.make()`; add point 3 |

The 30 other files using `Logger.make()` get the privacy fix automatically — no changes needed.

---

## Out of Scope

- No UI debug panel (deferred)
- No `os_signpost` timing traces
- No new log categories or structured logging format
