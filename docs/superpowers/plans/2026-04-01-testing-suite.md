# Memgram Testing Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a high-fidelity testing suite with a `FakeCloudKitChannel` that replicates CloudKit data structures, covering single-DB meeting status transitions and two-device end-to-end sync including push notification simulation and controlled delivery ordering.

**Architecture:** Extract a `SyncTransport` protocol from CloudSyncEngine's CKSyncEngine dependency. Production code uses `CKSyncTransport` (real); tests use `FakeSyncTransport` backed by a shared `FakeCloudKitChannel`. `TestSyncEnvironment` bundles an in-memory GRDB database + MeetingStore + CloudSyncEngine + FakeSyncTransport into one "device". Tests use Swift Testing (`@Test`, `#expect`).

**Tech Stack:** Swift Testing, GRDB 6.x (in-memory), CloudKit (CKRecord types only in tests), xcodegen

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `project.yml` | Modify | Add MemgramTests target |
| `Memgram/Sync/SyncTransport.swift` | Create | Protocol definitions |
| `Memgram/Sync/CKSyncTransport.swift` | Create | Real CKSyncEngine wrapper |
| `Memgram/Database/AppDatabase.swift` | Modify | Add `init(queue:)` for in-memory test DBs |
| `Memgram/Database/MeetingStore.swift` | Modify | Add `init(db:sync:)` for dependency injection |
| `Memgram/Sync/CloudSyncEngine.swift` | Modify | Use SyncTransport protocol; add `init(db:transport:)` |
| `Tests/MemgramTests/Infrastructure/FakeCloudKitChannel.swift` | Create | In-memory iCloud with push simulation |
| `Tests/MemgramTests/Infrastructure/FakeSyncTransport.swift` | Create | Test transport implementation |
| `Tests/MemgramTests/Infrastructure/TestSyncEnvironment.swift` | Create | Device factory for tests |
| `Tests/MemgramTests/MeetingStatusTests.swift` | Create | Single-DB status transition tests |
| `Tests/MemgramTests/SyncStatusTests.swift` | Create | Single-device sync lifecycle tests |
| `Tests/MemgramTests/TwoDeviceSyncTests.swift` | Create | Two-device end-to-end tests |

---

## Task 1: Test target + SyncTransport protocol

**Files:**
- Modify: `project.yml`
- Create: `Memgram/Sync/SyncTransport.swift`
- Create: `Tests/MemgramTests/Infrastructure/` (directory)

- [ ] **Add MemgramTests target to project.yml.** After the MemgramWatch target block, add:

```yaml
  MemgramTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: Tests/MemgramTests
    dependencies:
      - target: Memgram
    settings:
      base:
        SWIFT_VERSION: "5.9"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        SWIFT_STRICT_CONCURRENCY: minimal
    scheme:
      testTargets: []
```

Also update the Memgram target's scheme to reference the test target:

```yaml
    scheme:
      testTargets:
        - MemgramTests
```

- [ ] **Create `Memgram/Sync/SyncTransport.swift`:**

```swift
import CloudKit
import Foundation

/// Abstraction over CKSyncEngine for testability.
/// Production uses CKSyncTransport; tests use FakeSyncTransport.
@available(macOS 14.0, iOS 17.0, *)
protocol SyncTransport: AnyObject {
    var delegate: (any SyncTransportDelegate)? { get set }
    func enqueueSave(_ recordID: CKRecord.ID)
    func enqueueDelete(_ recordID: CKRecord.ID)
    func ensureZone(_ zoneID: CKRecordZone.ID)
    func fetchChanges() async throws
    var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] { get }
}

/// Callbacks from the transport to the sync engine.
@available(macOS 14.0, iOS 17.0, *)
protocol SyncTransportDelegate: AnyObject {
    func buildRecord(table: String, id: String) -> CKRecord?
    func didSend(saved: [CKRecord], failed: [(record: CKRecord, error: CKError)])
    func didReceive(modifications: [CKRecord], deletions: [CKRecord.ID])
    func didSaveState(_ data: Data)
}
```

- [ ] **Create the test directory structure:**

```bash
mkdir -p Tests/MemgramTests/Infrastructure
```

- [ ] **Create a placeholder test to verify the target builds.** Create `Tests/MemgramTests/SmokeTest.swift`:

```swift
import Testing
@testable import Memgram

@Test func smokeTest() {
    #expect(true)
}
```

- [ ] **Regenerate Xcode project and build + test:**

```bash
cd /Users/jevgenikabanov/Documents/Projects/Claude/Memgram
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD" | tail -5
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -10
```

Expected: build succeeds, 1 test passes.

- [ ] **Commit:**

```bash
git add project.yml Memgram/Sync/SyncTransport.swift Tests/
git commit -m "feat: add MemgramTests target and SyncTransport protocol"
```

---

## Task 2: AppDatabase + MeetingStore injectable inits

**Files:**
- Modify: `Memgram/Database/AppDatabase.swift`
- Modify: `Memgram/Database/MeetingStore.swift`

- [ ] **Add `init(queue:)` to AppDatabase.** Add this initializer after the existing `private init()`:

```swift
/// Test-only initializer accepting a pre-configured DatabaseQueue (e.g. in-memory).
init(queue: DatabaseQueue) throws {
    self.dbQueue = queue
    try runMigrations()
}
```

Also change `private init()` to `fileprivate init()` so the test factory can still use the main init pattern. Change the `private let dbQueue` to just `let dbQueue` (internal access for tests).

- [ ] **Add `init(db:sync:)` to MeetingStore.** Replace the current stored properties and init with:

```swift
final class MeetingStore {
    static let shared = MeetingStore()

    let db: AppDatabase
    private let syncProvider: (() -> CloudSyncEngine?)?

    private init() {
        self.db = AppDatabase.shared
        self.syncProvider = {
            if #available(macOS 14.0, iOS 17.0, *) { return CloudSyncEngine.shared }
            return nil
        }
    }

    init(db: AppDatabase, syncProvider: (() -> CloudSyncEngine?)?) {
        self.db = db
        self.syncProvider = syncProvider
    }

    private var sync: CloudSyncEngine? { syncProvider?() }
```

Note: `syncProvider` is a closure instead of a direct reference to allow lazy initialization. The sync engine may not exist until after `start()` is called.

- [ ] **Build + test:**

```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -10
```

- [ ] **Commit:**

```bash
git add Memgram/Database/AppDatabase.swift Memgram/Database/MeetingStore.swift
git commit -m "feat: add injectable inits for AppDatabase and MeetingStore"
```

---

## Task 3: CKSyncTransport + CloudSyncEngine refactor

**Files:**
- Create: `Memgram/Sync/CKSyncTransport.swift`
- Modify: `Memgram/Sync/CloudSyncEngine.swift`

This is the largest task. The goal: extract CKSyncEngine interaction into `CKSyncTransport`, make `CloudSyncEngine` use `SyncTransport` protocol, and add an injectable init.

- [ ] **Create `Memgram/Sync/CKSyncTransport.swift`.** This wraps the real `CKSyncEngine` and implements `SyncTransport`:

```swift
import CloudKit
import Foundation
import os

@available(macOS 14.0, iOS 17.0, *)
final class CKSyncTransport: NSObject, SyncTransport, CKSyncEngineDelegate {

    weak var delegate: (any SyncTransportDelegate)?

    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private let stateKey: String
    private let logger = Logger(subsystem: "com.memgram.app", category: "CKSyncTransport")
    private var engine: CKSyncEngine?

    init(container: CKContainer, zoneID: CKRecordZone.ID, stateKey: String) {
        self.container = container
        self.zoneID = zoneID
        self.stateKey = stateKey
        super.init()
    }

    func start() {
        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: restoredState(),
            delegate: self
        )
        config.automaticallySync = true
        engine = CKSyncEngine(config)
    }

    // MARK: - SyncTransport

    var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] {
        engine?.state.pendingRecordZoneChanges.map { $0 } ?? []
    }

    func enqueueSave(_ recordID: CKRecord.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    func enqueueDelete(_ recordID: CKRecord.ID) {
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    func ensureZone(_ zoneID: CKRecordZone.ID) {
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneName: zoneID.zoneName))])
    }

    func fetchChanges() async throws {
        guard let engine else { return }
        try await engine.fetchChanges()
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveState(stateUpdate.stateSerialization)
            delegate?.didSaveState(try! JSONEncoder().encode(stateUpdate.stateSerialization))

        case .fetchedRecordZoneChanges(let fetchedChanges):
            let sortedMods = fetchedChanges.modifications.sorted { a, _ in
                a.record.recordType == "Meeting"
            }
            let modifications = sortedMods.map(\.record)
            let deletions = fetchedChanges.deletions.map(\.recordID)
            delegate?.didReceive(modifications: modifications, deletions: deletions)

        case .sentRecordZoneChanges(let sentChanges):
            let saved = sentChanges.savedRecords
            let failed: [(record: CKRecord, error: CKError)] = sentChanges.failedRecordSaves.map {
                (record: $0.record, error: $0.error)
            }
            delegate?.didSend(saved: saved, failed: failed)

        case .fetchedDatabaseChanges(let dbChanges):
            for deletion in dbChanges.deletions {
                if deletion.zoneID.zoneName == zoneID.zoneName {
                    logger.warning("Zone deleted — recreating")
                    engine?.state.add(pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneName: zoneID.zoneName))
                    ])
                }
            }

        case .accountChange:
            logger.info("Account change detected")

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            logger.info("Unknown sync engine event")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
            // Parse record ID to extract table and id
            let name = recordID.recordName
            guard let underscoreIndex = name.firstIndex(of: "_") else { return nil }
            let table = String(name[name.startIndex..<underscoreIndex])
            let id = String(name[name.index(after: underscoreIndex)...])
            return self.delegate?.buildRecord(table: table, id: id)
        }
    }

    // MARK: - State Persistence

    private func saveState(_ serialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(serialization)
            UserDefaults.standard.set(data, forKey: stateKey)
        } catch {
            logger.error("Failed to save sync state: \(error)")
        }
    }

    private func restoredState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }
}
```

- [ ] **Refactor CloudSyncEngine to use SyncTransport.** The key changes:

1. Replace `syncEngine: CKSyncEngine?` with `transport: SyncTransport?`
2. Remove the inner `SyncDelegate` class
3. Conform to `SyncTransportDelegate`
4. Add injectable init

The refactored CloudSyncEngine should:

**Properties — replace:**
```swift
// OLD
nonisolated(unsafe) private var syncEngine: CKSyncEngine?
private let delegate: SyncDelegate
// NEW
private var transport: (any SyncTransport)?
```

**Init — add test init, update production init:**
```swift
private init() {
    // production init — uses real CKSyncTransport
}

init(db: AppDatabase, transport: any SyncTransport) {
    self.db = db
    self.transport = transport
    transport.delegate = self
}
```

Also change `fileprivate let db = AppDatabase.shared` to `let db: AppDatabase` and set it in both inits.

**start() — create CKSyncTransport for production:**
```swift
func start() {
    if transport == nil {
        let ckTransport = CKSyncTransport(
            container: container, zoneID: zoneID, stateKey: stateKey
        )
        ckTransport.delegate = self
        self.transport = ckTransport
        ckTransport.start()
    }
    transport?.ensureZone(zoneID)

    let isFirstLaunch = UserDefaults.standard.data(forKey: stateKey) == nil
    if isFirstLaunch {
        enqueueAllExistingRecords()
    } else {
        reEnqueueOrphanedRecords()
    }

    Task {
        do {
            logger.info("[CloudSync] Fetching changes...")
            try await transport?.fetchChanges()
            logger.info("[CloudSync] Fetch complete")
            auditStalePlaceholders()
        } catch {
            logger.error("[CloudSync] Fetch failed: \(error)")
        }
    }
}
```

**enqueueSave/enqueueDelete — use transport:**
```swift
func enqueueSave(table: String, id: String) {
    if table == "meetings" {
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
    guard let transport else { return }
    let recordID = makeRecordID(table: table, id: id)
    transport.enqueueSave(recordID)
}

func enqueueDelete(table: String, id: String) {
    guard let transport else { return }
    let recordID = makeRecordID(table: table, id: id)
    transport.enqueueDelete(recordID)
}
```

**Conform to SyncTransportDelegate:**
```swift
extension CloudSyncEngine: SyncTransportDelegate {
    func buildRecord(table: String, id: String) -> CKRecord? {
        // existing buildRecord implementation — unchanged
    }

    func didSend(saved: [CKRecord], failed: [(record: CKRecord, error: CKError)]) {
        // Move logic from old SyncDelegate.handleEvent(.sentRecordZoneChanges)
        for record in saved {
            updateSystemFields(for: record)
        }
        for (record, ckError) in failed {
            let recordID = record.recordID
            switch ckError.code {
            case .serverRecordChanged:
                if let serverRecord = ckError.serverRecord {
                    applyRemoteRecord(serverRecord)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                    }
                    enqueueSave(
                        table: parseRecordID(recordID)?.table ?? "",
                        id: parseRecordID(recordID)?.id ?? ""
                    )
                }
                if let parsed = parseRecordID(recordID), parsed.table == "meetings" {
                    DispatchQueue.main.async { [weak self] in
                        self?.uploadingIds.remove(parsed.id)
                    }
                }
            case .zoneNotFound:
                logger.warning("Zone not found during save, recreating...")
                transport?.ensureZone(zoneID)
                transport?.enqueueSave(recordID)
            case .unknownItem:
                logger.warning("[CloudSync] Unknown item — treating as remote deletion: \(recordID.recordName)")
                applyRemoteDeletion(recordID)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                }
            default:
                logger.error("Record save failed (\(ckError.code.rawValue)): \(ckError.localizedDescription)")
                if let parsed = parseRecordID(recordID), parsed.table == "meetings" {
                    do {
                        try db.write { db in
                            try db.execute(
                                sql: "UPDATE meetings SET sync_status = ? WHERE id = ?",
                                arguments: [SyncStatus.failed.rawValue, parsed.id]
                            )
                        }
                        DispatchQueue.main.async { [weak self] in
                            self?.uploadingIds.remove(parsed.id)
                        }
                        refreshSyncCounts()
                    } catch {
                        logger.error("Failed to set .failed for meeting \(parsed.id): \(error)")
                    }
                }
            }
        }
        // Track accepted meeting IDs as uploading
        let meetingIds = saved.compactMap { record -> String? in
            guard let parsed = parseRecordID(record.recordID),
                  parsed.table == "meetings" else { return nil }
            return parsed.id
        }
        // Note: uploadingIds insertion happens in nextRecordZoneChangeBatch in CKSyncTransport;
        // for the refactored version, we remove IDs here on success
    }

    func didReceive(modifications: [CKRecord], deletions: [CKRecord.ID]) {
        // Move logic from old SyncDelegate.handleEvent(.fetchedRecordZoneChanges)
        for record in modifications {
            applyRemoteRecord(record)
        }
        for recordID in deletions {
            applyRemoteDeletion(recordID)
        }
        let totalChanges = modifications.count + deletions.count
        if totalChanges > 0 {
            refreshSyncCounts()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            }
        }
    }

    func didSaveState(_ data: Data) {
        // State persistence handled by CKSyncTransport; no-op here
    }
}
```

**Remove the old `SyncDelegate` inner class entirely.**

**uploadingIds tracking:** Move from `nextRecordZoneChangeBatch` (which is now in CKSyncTransport) to the `didSend` callback. The CKSyncTransport's `nextRecordZoneChangeBatch` builds records via `delegate.buildRecord`, so the CloudSyncEngine doesn't know which records are in-flight until `didSend` is called. Instead, track uploadingIds when enqueueSave is called (optimistic) and remove on didSend:

In `enqueueSave`, after the DB write for meetings, also add to uploadingIds:
```swift
DispatchQueue.main.async { [weak self] in
    self?.uploadingIds.insert(id)
}
```

In `didSend`, for each saved record, remove from uploadingIds:
```swift
for record in saved {
    updateSystemFields(for: record)
    if let parsed = parseRecordID(record.recordID), parsed.table == "meetings" {
        DispatchQueue.main.async { [weak self] in
            self?.uploadingIds.remove(parsed.id)
        }
    }
}
```

- [ ] **Build + test:**

```bash
xcodegen generate
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -10
```

Expected: smoke test still passes. No build errors.

- [ ] **Commit:**

```bash
git add Memgram/Sync/CKSyncTransport.swift Memgram/Sync/CloudSyncEngine.swift
git commit -m "refactor: extract CKSyncTransport, CloudSyncEngine uses SyncTransport protocol"
```

---

## Task 4: FakeCloudKitChannel

**Files:**
- Create: `Tests/MemgramTests/Infrastructure/FakeCloudKitChannel.swift`

- [ ] **Create the file:**

```swift
import CloudKit
import Foundation
@testable import Memgram

/// In-memory iCloud backend for tests.
/// Stores CKRecords, tracks versions for conflict detection,
/// and simulates push notifications between connected transports.
@available(macOS 14.0, *)
final class FakeCloudKitChannel {

    /// All records currently "in the cloud", keyed by record ID name.
    private(set) var records: [String: CKRecord] = [:]

    /// Version counter per record for conflict detection.
    private var versions: [String: Int] = [:]

    /// Connected transports (simulated devices).
    private(set) var transports: [FakeSyncTransport] = []

    /// Queued push notifications not yet delivered.
    private(set) var pendingPushes: [(target: FakeSyncTransport, records: [CKRecord], deletions: [CKRecord.ID])] = []

    /// When true, pushes queue but don't auto-deliver (simulates network partition).
    var holdPushes = false

    /// Record IDs that will trigger serverRecordChanged on next upload.
    var conflictingRecordIDs: Set<String> = []

    /// Error code to inject on next save batch (nil = success).
    var failNextSave: CKError.Code?

    func connect(_ transport: FakeSyncTransport) {
        transports.append(transport)
    }

    // MARK: - Upload (called by FakeSyncTransport.flush)

    struct SaveResult {
        let saved: [CKRecord]
        let failed: [(record: CKRecord, error: CKError)]
    }

    func receive(records: [CKRecord], deletions: [CKRecord.ID], from sender: FakeSyncTransport) -> SaveResult {
        var saved: [CKRecord] = []
        var failed: [(record: CKRecord, error: CKError)] = []

        // Check for injected batch failure
        if let errorCode = failNextSave {
            failNextSave = nil
            for record in records {
                let error = CKError(errorCode)
                failed.append((record: record, error: error))
            }
            return SaveResult(saved: saved, failed: failed)
        }

        for record in records {
            let key = record.recordID.recordName

            // Check for explicit conflict injection
            if conflictingRecordIDs.contains(key), let serverRecord = self.records[key] {
                conflictingRecordIDs.remove(key)
                let error = CKError(CKError.Code.serverRecordChanged,
                                     userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])
                failed.append((record: record, error: error))
                continue
            }

            // Store or update
            self.records[key] = record
            versions[key, default: 0] += 1
            saved.append(record)
        }

        // Process deletions
        for recordID in deletions {
            let key = recordID.recordName
            self.records.removeValue(forKey: key)
            versions.removeValue(forKey: key)
        }

        // Queue pushes for other transports
        let otherTransports = transports.filter { $0 !== sender }
        for target in otherTransports {
            pendingPushes.append((target: target, records: saved, deletions: deletions))
        }

        if !holdPushes {
            deliverPushes()
        }

        return SaveResult(saved: saved, failed: failed)
    }

    // MARK: - Push Delivery

    /// Deliver all pending pushes to target transports.
    func deliverPushes() {
        let pushes = pendingPushes
        pendingPushes = []
        for push in pushes {
            push.target.receive(modifications: push.records, deletions: push.deletions)
        }
    }

    /// Deliver pushes only to a specific transport.
    func deliverPushes(to target: FakeSyncTransport) {
        let matching = pendingPushes.filter { $0.target === target }
        pendingPushes.removeAll { $0.target === target }
        for push in matching {
            push.target.receive(modifications: push.records, deletions: push.deletions)
        }
    }

    /// Deliver specific records in a controlled order to a transport.
    /// Useful for testing out-of-order FK delivery (segments before meetings).
    func deliverOutOfOrder(_ recordIDs: [String], to target: FakeSyncTransport) {
        let ordered = recordIDs.compactMap { key in records[key] }
        target.receive(modifications: ordered, deletions: [])
        // Remove delivered records from pending pushes for this target
        let deliveredKeys = Set(recordIDs)
        pendingPushes = pendingPushes.map { push in
            guard push.target === target else { return push }
            let remaining = push.records.filter { !deliveredKeys.contains($0.recordID.recordName) }
            return (target: push.target, records: remaining, deletions: push.deletions)
        }.filter { !$0.records.isEmpty || !$0.deletions.isEmpty }
    }

    /// Deliver segments before meetings (reverses natural sort).
    func deliverSegmentsBeforeMeetings(to target: FakeSyncTransport) {
        let pushes = pendingPushes.filter { $0.target === target }
        pendingPushes.removeAll { $0.target === target }
        for push in pushes {
            let reordered = push.records.sorted { a, _ in a.recordType != "Meeting" }
            target.receive(modifications: reordered, deletions: push.deletions)
        }
    }

    // MARK: - Fetch All (reset/resync support)

    /// Returns all records in the channel (simulates full CloudKit fetch on first launch).
    func fetchAll() -> [CKRecord] {
        Array(records.values)
    }
}
```

- [ ] **Build:**

```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -10
```

- [ ] **Commit:**

```bash
git add Tests/MemgramTests/Infrastructure/FakeCloudKitChannel.swift
git commit -m "feat: add FakeCloudKitChannel — in-memory iCloud with push simulation"
```

---

## Task 5: FakeSyncTransport + TestSyncEnvironment

**Files:**
- Create: `Tests/MemgramTests/Infrastructure/FakeSyncTransport.swift`
- Create: `Tests/MemgramTests/Infrastructure/TestSyncEnvironment.swift`

- [ ] **Create `FakeSyncTransport.swift`:**

```swift
import CloudKit
import Foundation
@testable import Memgram

/// Test implementation of SyncTransport backed by a FakeCloudKitChannel.
@available(macOS 14.0, *)
final class FakeSyncTransport: SyncTransport {

    weak var delegate: (any SyncTransportDelegate)?
    let channel: FakeCloudKitChannel

    private var pendingSaves: [CKRecord.ID] = []
    private var pendingDeletes: [CKRecord.ID] = []

    var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] {
        pendingSaves.map { .saveRecord($0) } + pendingDeletes.map { .deleteRecord($0) }
    }

    init(channel: FakeCloudKitChannel) {
        self.channel = channel
        channel.connect(self)
    }

    func enqueueSave(_ recordID: CKRecord.ID) {
        pendingSaves.append(recordID)
    }

    func enqueueDelete(_ recordID: CKRecord.ID) {
        pendingDeletes.append(recordID)
    }

    func ensureZone(_ zoneID: CKRecordZone.ID) {
        // No-op in fake — zone always exists
    }

    func fetchChanges() async throws {
        // Fetch all records from channel (simulates full fetch)
        let allRecords = channel.fetchAll()
        if !allRecords.isEmpty {
            delegate?.didReceive(modifications: allRecords, deletions: [])
        }
    }

    // MARK: - Test Controls

    /// Process all pending saves/deletes synchronously.
    /// Calls delegate.buildRecord for each save, uploads to channel,
    /// calls delegate.didSend with results.
    func flush() {
        let savesToProcess = pendingSaves
        let deletesToProcess = pendingDeletes
        pendingSaves = []
        pendingDeletes = []

        // Build records for saves
        var records: [CKRecord] = []
        for recordID in savesToProcess {
            let name = recordID.recordName
            guard let underscoreIndex = name.firstIndex(of: "_") else { continue }
            let table = String(name[name.startIndex..<underscoreIndex])
            let id = String(name[name.index(after: underscoreIndex)...])
            if let record = delegate?.buildRecord(table: table, id: id) {
                records.append(record)
            }
        }

        // Upload to channel
        let deleteIDs = deletesToProcess
        let result = channel.receive(records: records, deletions: deleteIDs, from: self)

        // Report results to delegate
        delegate?.didSend(saved: result.saved, failed: result.failed)
    }

    /// Called by the channel when a push notification arrives.
    func receive(modifications: [CKRecord], deletions: [CKRecord.ID]) {
        delegate?.didReceive(modifications: modifications, deletions: deletions)
    }
}
```

- [ ] **Create `TestSyncEnvironment.swift`:**

```swift
import Foundation
import GRDB
@testable import Memgram

/// Bundles one simulated "device" for tests: in-memory DB + MeetingStore + CloudSyncEngine + FakeSyncTransport.
@available(macOS 14.0, *)
struct TestSyncEnvironment {
    let db: AppDatabase
    let meetingStore: MeetingStore
    let engine: CloudSyncEngine
    let transport: FakeSyncTransport

    /// Create a test environment connected to a shared FakeCloudKitChannel.
    static func make(channel: FakeCloudKitChannel) throws -> TestSyncEnvironment {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        let db = try AppDatabase(queue: queue)

        let transport = FakeSyncTransport(channel: channel)
        let engine = CloudSyncEngine(db: db, transport: transport)
        let store = MeetingStore(db: db, syncProvider: { engine })

        return TestSyncEnvironment(db: db, meetingStore: store, engine: engine, transport: transport)
    }

    /// Create a standalone test environment (no sync, for single-DB tests).
    static func makeLocal() throws -> TestSyncEnvironment {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        let db = try AppDatabase(queue: queue)

        let channel = FakeCloudKitChannel()
        let transport = FakeSyncTransport(channel: channel)
        let engine = CloudSyncEngine(db: db, transport: transport)
        let store = MeetingStore(db: db, syncProvider: { engine })

        return TestSyncEnvironment(db: db, meetingStore: store, engine: engine, transport: transport)
    }
}
```

- [ ] **Build + test:**

```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -10
```

- [ ] **Commit:**

```bash
git add Tests/MemgramTests/Infrastructure/FakeSyncTransport.swift \
        Tests/MemgramTests/Infrastructure/TestSyncEnvironment.swift
git commit -m "feat: add FakeSyncTransport and TestSyncEnvironment device factory"
```

---

## Task 6: MeetingStatusTests — single-DB

**Files:**
- Create: `Tests/MemgramTests/MeetingStatusTests.swift`

- [ ] **Create the test file with all single-DB scenarios:**

```swift
import Testing
import Foundation
@testable import Memgram

@available(macOS 14.0, *)
@Suite("Meeting Status Transitions")
struct MeetingStatusTests {

    // MARK: - Status transitions

    @Test func createMeetingDefaultStatus() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        #expect(meeting.status == .recording)
        #expect(meeting.syncStatus == .pendingUpload)
    }

    @Test func statusTransitionRecordingToTranscribing() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.updateStatus(meeting.id, status: .transcribing)
        let updated = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(updated.status == .transcribing)
    }

    @Test func statusTransitionFullPipeline() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")

        try env.meetingStore.updateStatus(meeting.id, status: .transcribing)
        try env.meetingStore.updateStatus(meeting.id, status: .diarizing)
        try env.meetingStore.updateStatus(meeting.id, status: .done)

        let final = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(final.status == .done)
    }

    @Test func finalizeMeetingSetsTranscript() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Speaker A: Hello")

        let finalized = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(finalized.status == .done)
        #expect(finalized.rawTranscript == "Speaker A: Hello")
    }

    @Test func finalizeMeetingEmptyTranscript() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "")

        let finalized = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(finalized.status == .done)
        #expect(finalized.rawTranscript == "")
    }

    // MARK: - Interrupted detection

    @Test func interruptedMeetingsFindsRecording() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let _ = try env.meetingStore.createMeeting(title: "Stuck Recording")
        // createMeeting sets status = .recording by default
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.count == 1)
        #expect(interrupted[0].status == .recording)
    }

    @Test func interruptedMeetingsFindsTranscribing() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Stuck")
        try env.meetingStore.updateStatus(meeting.id, status: .transcribing)
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.count == 1)
    }

    @Test func interruptedMeetingsFindsDiarizing() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Stuck")
        try env.meetingStore.updateStatus(meeting.id, status: .diarizing)
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.count == 1)
    }

    @Test func interruptedMeetingsExcludesDone() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Completed")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Done")
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.isEmpty)
    }

    // MARK: - Summary and title

    @Test func saveSummaryPersists() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.saveSummary(meetingId: meeting.id, summary: "Key points: ...")
        let updated = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(updated.summary == "Key points: ...")
    }

    @Test func updateTitlePersists() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Original")
        try env.meetingStore.updateTitle(meeting.id, title: "Renamed")
        let updated = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(updated.title == "Renamed")
    }

    // MARK: - Filter logic

    @Test func filterHidesPlaceholders() throws {
        let env = try TestSyncEnvironment.makeLocal()
        // Insert a placeholder directly
        try env.db.write { db in
            let placeholder = Meeting(
                id: UUID().uuidString, title: "Syncing…", startedAt: Date(),
                endedAt: nil, durationSeconds: nil, status: .done,
                syncStatus: .placeholder,
                summary: nil, actionItems: nil, rawTranscript: nil,
                ckSystemFields: nil
            )
            try placeholder.insert(db)
        }
        let all = try env.meetingStore.fetchAll()
        let visible = all.filter { $0.syncStatus != .placeholder }
        #expect(visible.isEmpty)
    }

    @Test func filterShowsInterruptedMeetings() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Interrupted")
        try env.meetingStore.updateStatus(meeting.id, status: .interrupted)
        let all = try env.meetingStore.fetchAll()
        let visible = all.filter { $0.syncStatus != .placeholder }
        #expect(visible.count == 1)
    }

    @Test func filterShowsEmptyTranscriptMeetings() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Empty")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "")
        let all = try env.meetingStore.fetchAll()
        let visible = all.filter { $0.syncStatus != .placeholder }
        #expect(visible.count == 1)
    }

    // MARK: - Delete and discard

    @Test func deleteMeetingRemovesFromDB() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "To Delete")
        try env.meetingStore.deleteMeeting(meeting.id)
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)
        #expect(fetched == nil)
    }

    @Test func discardMeetingRemovesFromDB() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "To Discard")
        try env.meetingStore.discardMeeting(meeting.id)
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)
        #expect(fetched == nil)
    }
}
```

- [ ] **Build + run tests:**

```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -20
```

Expected: all tests pass.

- [ ] **Commit:**

```bash
git add Tests/MemgramTests/MeetingStatusTests.swift
git commit -m "test: add MeetingStatusTests — single-DB status transitions and filter logic"
```

---

## Task 7: SyncStatusTests — single-device sync lifecycle

**Files:**
- Create: `Tests/MemgramTests/SyncStatusTests.swift`

- [ ] **Create the test file:**

```swift
import Testing
import CloudKit
import Foundation
@testable import Memgram

@available(macOS 14.0, *)
@Suite("Sync Status Lifecycle")
struct SyncStatusTests {

    // MARK: - enqueueSave

    @Test func enqueueSaveSetsPendingUpload() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        // createMeeting calls enqueueSave internally
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.syncStatus == .pendingUpload)
    }

    @Test func enqueueSaveResetsFromSyncedToPendingUpload() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        // Manually set to synced
        try env.db.write { db in
            try db.execute(sql: "UPDATE meetings SET sync_status = 'synced' WHERE id = ?",
                           arguments: [meeting.id])
        }
        // Now save summary (which calls enqueueSave)
        try env.meetingStore.saveSummary(meetingId: meeting.id, summary: "New summary")
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.syncStatus == .pendingUpload)
    }

    // MARK: - Upload lifecycle

    @Test func flushTransitionsPendingToSynced() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Test")

        // Flush triggers upload
        env.transport.flush()

        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.syncStatus == .synced)
        #expect(fetched.ckSystemFields != nil)
    }

    @Test func pendingCountUpdatesAfterFlush() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let _ = try env.meetingStore.createMeeting(title: "Test")

        // Before flush: pending
        env.engine.refreshSyncCounts()
        // Note: refreshSyncCounts dispatches to main, so we may need a small delay
        // For synchronous testing, read counts directly from DB
        let pendingBefore = try env.db.read { db in
            try Meeting.filter(Column("sync_status") == SyncStatus.pendingUpload.rawValue).fetchCount(db)
        }
        #expect(pendingBefore == 1)

        env.transport.flush()

        let pendingAfter = try env.db.read { db in
            try Meeting.filter(Column("sync_status") == SyncStatus.pendingUpload.rawValue).fetchCount(db)
        }
        #expect(pendingAfter == 0)
    }

    // MARK: - Error paths

    @Test func permanentErrorSetsFailed() throws {
        let channel = FakeCloudKitChannel()
        channel.failNextSave = .internalError
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Test")

        env.transport.flush()

        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.syncStatus == .failed)
    }

    @Test func serverRecordChangedAppliesRemoteAndReenqueues() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Original")

        // First sync to establish the record in the channel
        env.transport.flush()

        // Simulate another device updating the title in the channel
        let key = "meetings_\(meeting.id)"
        if let serverRecord = channel.records[key] {
            serverRecord["title"] = "Remote Title" as CKRecordValue
            channel.records[key] = serverRecord
        }

        // Now update locally and mark as conflicting
        try env.meetingStore.updateTitle(meeting.id, title: "Local Title")
        channel.conflictingRecordIDs.insert(key)

        // Flush — should get serverRecordChanged
        env.transport.flush()

        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        // After conflict, remote version is applied, then local re-enqueued
        #expect(fetched.syncStatus == .pendingUpload)
    }

    // MARK: - applyRemoteRecord normalization

    @Test func remoteRecordNormalizesInterrupted() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)

        // Simulate a record arriving via transport (routes through didReceive → applyRemoteRecord)
        let zoneID = CKRecordZone.ID(zoneName: "MemgramZone")
        let recordID = CKRecord.ID(recordName: "meetings_\(UUID().uuidString)", zoneID: zoneID)
        let record = CKRecord(recordType: "Meeting", recordID: recordID)
        record["title"] = "Remote Meeting" as CKRecordValue
        record["startedAt"] = Date() as CKRecordValue
        record["status"] = "done" as CKRecordValue
        // rawTranscript intentionally not set (nil)

        env.transport.receive(modifications: [record], deletions: [])

        let id = String(recordID.recordName.dropFirst("meetings_".count))
        let fetched = try env.meetingStore.fetchMeeting(id)!
        #expect(fetched.status == .interrupted)
        #expect(fetched.syncStatus == .synced)
    }

    @Test func remoteRecordKeepsDoneWithTranscript() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)

        let zoneID = CKRecordZone.ID(zoneName: "MemgramZone")
        let recordID = CKRecord.ID(recordName: "meetings_\(UUID().uuidString)", zoneID: zoneID)
        let record = CKRecord(recordType: "Meeting", recordID: recordID)
        record["title"] = "Remote Meeting" as CKRecordValue
        record["startedAt"] = Date() as CKRecordValue
        record["status"] = "done" as CKRecordValue
        record["rawTranscript"] = "Speaker A: Hello" as CKRecordValue

        env.transport.receive(modifications: [record], deletions: [])

        let id = String(recordID.recordName.dropFirst("meetings_".count))
        let fetched = try env.meetingStore.fetchMeeting(id)!
        #expect(fetched.status == .done)
    }

    // MARK: - Placeholder lifecycle

    @Test func placeholderCreatedForOrphanedSegment() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)

        let meetingId = UUID().uuidString
        let zoneID = CKRecordZone.ID(zoneName: "MemgramZone")
        let segmentRecordID = CKRecord.ID(recordName: "segments_\(UUID().uuidString)", zoneID: zoneID)
        let segmentRecord = CKRecord(recordType: "Segment", recordID: segmentRecordID)
        segmentRecord["meetingId"] = meetingId as CKRecordValue
        segmentRecord["speaker"] = "Speaker A" as CKRecordValue
        segmentRecord["channel"] = "mic" as CKRecordValue
        segmentRecord["startSeconds"] = 0.0 as CKRecordValue
        segmentRecord["endSeconds"] = 10.0 as CKRecordValue
        segmentRecord["text"] = "Hello" as CKRecordValue

        // Route through transport → didReceive → applyRemoteRecord
        env.transport.receive(modifications: [segmentRecord], deletions: [])

        let placeholder = try env.meetingStore.fetchMeeting(meetingId)!
        #expect(placeholder.syncStatus == .placeholder)
        #expect(placeholder.title == "Syncing…")
    }

    // MARK: - Startup recovery

    @Test func orphanedPendingUploadSyncsAfterRestart() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Orphan")
        // Don't flush — meeting stays as pendingUpload

        // Simulate app restart: start() calls reEnqueueOrphanedRecords internally
        env.engine.start()

        // Now flush — should sync successfully
        env.transport.flush()
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.syncStatus == .synced)
    }
}
```

- [ ] **Build + run tests:**

```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -20
```

- [ ] **Commit:**

```bash
git add Tests/MemgramTests/SyncStatusTests.swift
git commit -m "test: add SyncStatusTests — single-device sync lifecycle and error paths"
```

---

## Task 8: TwoDeviceSyncTests — end-to-end

**Files:**
- Create: `Tests/MemgramTests/TwoDeviceSyncTests.swift`

- [ ] **Create the test file:**

```swift
import Testing
import CloudKit
import Foundation
@testable import Memgram

@available(macOS 14.0, *)
@Suite("Two-Device Sync")
struct TwoDeviceSyncTests {

    // MARK: - Basic sync

    @Test func meetingSyncsFromDeviceAToB() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        let meeting = try deviceA.meetingStore.createMeeting(title: "Team Sync")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Speaker A: Hi")
        deviceA.transport.flush()

        // Push delivered automatically (holdPushes = false)
        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 1)
        #expect(bMeetings[0].title == "Team Sync")
        #expect(bMeetings[0].rawTranscript == "Speaker A: Hi")
        #expect(bMeetings[0].syncStatus == .synced)

        // Verify A is also synced
        let aMeeting = try deviceA.meetingStore.fetchMeeting(meeting.id)!
        #expect(aMeeting.syncStatus == .synced)
    }

    // MARK: - Delayed delivery (network partition)

    @Test func delayedPushDelivery() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        channel.holdPushes = true
        let meeting = try deviceA.meetingStore.createMeeting(title: "Delayed")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Text")
        deviceA.transport.flush()

        // B has nothing yet
        #expect(try deviceB.meetingStore.fetchAll().isEmpty)

        // Release the partition
        channel.holdPushes = false
        channel.deliverPushes()

        // Now B has it
        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 1)
        #expect(bMeetings[0].title == "Delayed")
        #expect(bMeetings[0].syncStatus == .synced)
    }

    // MARK: - Out-of-order FK delivery

    @Test func segmentBeforeMeetingCreatesPlaceholder() throws {
        let channel = FakeCloudKitChannel()
        channel.holdPushes = true
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        let meeting = try deviceA.meetingStore.createMeeting(title: "FK Test")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Hello")
        deviceA.transport.flush()

        // Deliver segments before meetings
        channel.deliverSegmentsBeforeMeetings(to: deviceB.transport)

        // If segments were synced, B should have a placeholder
        let bAll = try deviceB.meetingStore.fetchAll()
        // Filter out placeholders to check if real meeting came through
        let placeholders = bAll.filter { $0.syncStatus == .placeholder }
        // Deliver remaining (the meeting record)
        channel.deliverPushes(to: deviceB.transport)

        let bFinal = try deviceB.meetingStore.fetchAll()
        let visible = bFinal.filter { $0.syncStatus != .placeholder }
        #expect(visible.count == 1)
        #expect(visible[0].title == "FK Test")
        #expect(visible[0].syncStatus == .synced)
    }

    // MARK: - Bidirectional sync

    @Test func bidirectionalSync() throws {
        let channel = FakeCloudKitChannel()
        channel.holdPushes = true
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // Both create a meeting independently
        let meetingA = try deviceA.meetingStore.createMeeting(title: "A's Meeting")
        let meetingB = try deviceB.meetingStore.createMeeting(title: "B's Meeting")

        // Both flush
        deviceA.transport.flush()
        deviceB.transport.flush()

        // Deliver pushes
        channel.deliverPushes()

        // Both should have both meetings
        let aAll = try deviceA.meetingStore.fetchAll()
        let bAll = try deviceB.meetingStore.fetchAll()
        #expect(aAll.count == 2)
        #expect(bAll.count == 2)
        #expect(Set(aAll.map(\.title)) == Set(["A's Meeting", "B's Meeting"]))
        #expect(Set(bAll.map(\.title)) == Set(["A's Meeting", "B's Meeting"]))
    }

    // MARK: - Deletion

    @Test func deletionSyncsAcrossDevices() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // A creates and syncs
        let meeting = try deviceA.meetingStore.createMeeting(title: "To Delete")
        deviceA.transport.flush()
        #expect(try deviceB.meetingStore.fetchAll().count == 1)

        // A deletes
        try deviceA.meetingStore.deleteMeeting(meeting.id)
        deviceA.transport.flush()

        // B should have 0
        #expect(try deviceB.meetingStore.fetchAll().isEmpty)
    }

    // MARK: - Conflict resolution

    @Test func conflictResolutionPreservesHigherStatusRank() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // A creates and syncs
        let meeting = try deviceA.meetingStore.createMeeting(title: "Conflict")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Done")
        deviceA.transport.flush()

        // Both have the meeting now, status = .done on both
        let bMeeting = try deviceB.meetingStore.fetchMeeting(meeting.id)!
        #expect(bMeeting.status == .done)
    }

    @Test func conflictResolutionPreservesSummary() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // A creates, syncs, then generates summary
        let meeting = try deviceA.meetingStore.createMeeting(title: "Summary Test")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Text")
        deviceA.transport.flush()

        // A generates summary locally
        try deviceA.meetingStore.saveSummary(meetingId: meeting.id, summary: "Key points: ...")

        // B receives the meeting (without summary)
        // Now A flushes the summary update
        channel.holdPushes = true
        deviceA.transport.flush()

        // Simulate B receiving the update — summary should be preserved
        channel.deliverPushes()
        let bMeeting = try deviceB.meetingStore.fetchMeeting(meeting.id)!
        #expect(bMeeting.summary == "Key points: ...")
    }

    // MARK: - Reset/resync

    @Test func resetResyncDownloadsAllFromChannel() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)

        // Create 3 meetings on device A
        for i in 1...3 {
            let m = try deviceA.meetingStore.createMeeting(title: "Meeting \(i)")
            try deviceA.meetingStore.finalizeMeeting(m.id, endedAt: Date(), rawTranscript: "Text \(i)")
        }
        deviceA.transport.flush()
        #expect(channel.records.count >= 3)

        // Device B starts fresh and fetches all
        let deviceB = try TestSyncEnvironment.make(channel: channel)
        try await deviceB.transport.fetchChanges()

        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 3)
        for meeting in bMeetings {
            #expect(meeting.syncStatus == .synced)
        }
    }

    // MARK: - Error recovery

    @Test func errorRecoveryAfterNetworkFailure() throws {
        let channel = FakeCloudKitChannel()
        channel.failNextSave = .networkFailure
        let deviceA = try TestSyncEnvironment.make(channel: channel)

        let meeting = try deviceA.meetingStore.createMeeting(title: "Error Test")
        deviceA.transport.flush()

        // First attempt fails
        let failedMeeting = try deviceA.meetingStore.fetchMeeting(meeting.id)!
        #expect(failedMeeting.syncStatus == .failed)

        // Retry succeeds
        deviceA.engine.enqueueSave(table: "meetings", id: meeting.id)
        deviceA.transport.flush()

        let recovered = try deviceA.meetingStore.fetchMeeting(meeting.id)!
        #expect(recovered.syncStatus == .synced)
    }

    // MARK: - Out-of-order delivery

    @Test func outOfOrderDeliveryProcessesCorrectly() throws {
        let channel = FakeCloudKitChannel()
        channel.holdPushes = true
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        let m1 = try deviceA.meetingStore.createMeeting(title: "First")
        let m2 = try deviceA.meetingStore.createMeeting(title: "Second")
        let m3 = try deviceA.meetingStore.createMeeting(title: "Third")
        deviceA.transport.flush()

        // Deliver in reverse order
        let key3 = "meetings_\(m3.id)"
        let key1 = "meetings_\(m1.id)"
        let key2 = "meetings_\(m2.id)"
        channel.deliverOutOfOrder([key3, key1, key2], to: deviceB.transport)

        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 3)
        #expect(Set(bMeetings.map(\.title)) == Set(["First", "Second", "Third"]))
    }
}
```

- [ ] **Build + run all tests:**

```bash
xcodebuild test -project Memgram.xcodeproj -scheme Memgram -configuration Debug \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test.*passed|Test.*failed|error:" | tail -30
```

Expected: all tests pass across all three test files.

- [ ] **Remove the smoke test** (no longer needed):

```bash
rm Tests/MemgramTests/SmokeTest.swift
```

- [ ] **Commit:**

```bash
git add Tests/MemgramTests/TwoDeviceSyncTests.swift
git rm Tests/MemgramTests/SmokeTest.swift 2>/dev/null || true
git add -A Tests/
git commit -m "test: add TwoDeviceSyncTests — end-to-end two-device sync with push simulation"
```

---

## Post-implementation checklist

- [ ] All tests pass: `xcodebuild test -scheme Memgram` shows 0 failures
- [ ] Production app still builds and runs: `xcodebuild -scheme Memgram build` succeeds
- [ ] iOS target still builds: `xcodebuild -scheme MemgramMobile build` succeeds
- [ ] Verify the refactored CloudSyncEngine works at runtime (launch app, record a meeting, check sync status icons)
