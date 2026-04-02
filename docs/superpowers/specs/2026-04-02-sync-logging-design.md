# Sync Logging Instrumentation

**Date:** 2026-04-02  
**Status:** Approved  
**Goal:** Make CloudKit sync fully observable via Console.app to debug meetings diverging across devices even after re-sync.

---

## Problem

Two symptoms observed:
1. Each device shows meetings the other doesn't, even after `resetAndResync()` on both sides.
2. Console.app logs are useless for diagnosis because all dynamic values (`id`, `meetingId`, error details) are redacted as `<private>` by OSLog's default privacy policy.

This design addresses both.

---

## Approach

**C1 — Surgical annotation + gap-fill** in `CloudSyncEngine.swift` and `CKSyncTransport.swift`. No new files, no new abstractions. Two changes:

1. Add `privacy: .public` to every dynamic interpolation in existing log calls.
2. Add six missing log points that cover the full upload/download lifecycle.

---

## Privacy Fix

Every `\(someValue)` in both sync files gets annotated as `\(someValue, privacy: .public)`.

Scope of values being made public:
- Meeting/segment/speaker UUIDs — not personal data
- Table names (`"meetings"`, `"segments"`, `"speakers"`) — constants effectively  
- Record names (`recordID.recordName`) — same format as UUIDs
- Error codes (`.rawValue` ints) and `localizedDescription` — needed for diagnosis
- Counts (integers) — already public by OSLog convention but annotating explicitly for consistency

`Log.swift` is not changed. Privacy is controlled per call-site.

---

## Missing Instrumentation Points

Six log calls added, covering the full round-trip:

### 1. `enqueueSave(table:id:)` — entry
```
[CloudSync] Enqueued table/id for upload
```
Confirms the DB write triggered sync. Currently only logs on error.

### 2. `buildCKRecord(table:id:)` — success path
```
[CloudSync] Built record table/id (new | existing systemFields)
```
Confirms the CKRecord was constructed and handed to the engine. Currently only logs on error or unknown table.

### 3. `nextRecordZoneChangeBatch` — batch summary (in `CKSyncTransport`)
```
[CKSyncTransport] Sending batch of N records
```
Confirms CKSyncEngine is actually asking for records to upload. If this never fires, the engine isn't triggering sends.

### 4. `didSend` — per saved record
```
[CloudSync] Uploaded table/id successfully
```
Confirms CloudKit acknowledged the record. Currently `didSend` calls `updateSystemFields` silently on success.

### 5. `didSend` — per failed record with error code
```
[CloudSync] Upload failed for table/id — code N: description
```
Currently only logs for the `default` error case; `.serverRecordChanged`, `.zoneNotFound`, `.unknownItem` log warnings without the meeting ID.

### 6. `applyRemoteRecord` — meeting insert vs update + final status
```
[CloudSync] Applied meeting id — inserted | updated — finalStatus
```
Confirms what the receiving device stored. Currently meeting apply has no success log at all (only segments do).

---

## What This Enables in Console.app

Filter by subsystem `com.memgram.app` and category `CloudSync` or `CKSyncTransport`. With these changes you can correlate across devices:

| Question | Log point |
|---|---|
| Did device A enqueue the meeting? | Point 1 |
| Did CKSyncEngine build the record? | Point 2 |
| Did the engine attempt to send it? | Point 3 |
| Did CloudKit confirm receipt? | Point 4 |
| Why did upload fail? | Point 5 |
| Did device B receive and store it? | Point 6 |

A meeting missing on device B that exists on device A will show exactly where the chain broke.

---

## Files Changed

| File | Change |
|---|---|
| `Memgram/Sync/CloudSyncEngine.swift` | Privacy annotations on all existing log calls; add points 1, 2, 4, 5, 6 |
| `Memgram/Sync/CKSyncTransport.swift` | Privacy annotations on all existing log calls; add point 3 |

No other files touched.

---

## Out of Scope

- No UI debug panel (deferred)
- No `os_signpost` timing traces (not needed for this bug)
- No changes to `Log.swift` or other subsystems
- No new log categories or structured logging format
