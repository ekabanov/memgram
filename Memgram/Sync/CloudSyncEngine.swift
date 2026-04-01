import CloudKit
import Foundation
import GRDB
import os

// MARK: - CloudSyncEngine

@available(macOS 14.0, iOS 17.0, *)
final class CloudSyncEngine: ObservableObject {

    static let shared = CloudSyncEngine()

    fileprivate let container = CKContainer(identifier: "iCloud.com.memgram.app")
    fileprivate let zoneName = "MemgramZone"
    fileprivate let stateKey = "CKSyncEngineState"
    fileprivate let logger = Logger(subsystem: "com.memgram.app", category: "CloudSync")
    fileprivate let db = AppDatabase.shared

    fileprivate var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }

    nonisolated(unsafe) private var syncEngine: CKSyncEngine?
    nonisolated(unsafe) private var isResetting = false
    nonisolated(unsafe) private var fetchedDuringReset: Set<String> = []
    private let delegate: SyncDelegate

    @Published var uploadingIds: Set<String> = []
    @Published var pendingCount: Int = 0
    @Published var failedCount: Int = 0

    private init() {
        delegate = SyncDelegate()
        delegate.engine = self
    }

    // MARK: - Lifecycle

    func start() {
        let isFirstLaunch = UserDefaults.standard.data(forKey: stateKey) == nil
        logger.info("[CloudSync] Starting. isFirstLaunch=\(isFirstLaunch)")

        var config = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: restoredState(),
            delegate: delegate
        )
        config.automaticallySync = true

        let engine = CKSyncEngine(config)
        self.syncEngine = engine
        logger.info("[CloudSync] Engine created")

        // Ensure zone exists via CKSyncEngine (not direct API)
        engine.state.add(pendingDatabaseChanges: [
            .saveZone(CKRecordZone(zoneName: zoneName))
        ])

        if isFirstLaunch {
            enqueueAllExistingRecords()
        } else {
            // Re-enqueue records written locally but never acknowledged by CloudKit.
            // Safe to call every launch — CKSyncEngine deduplicates pending changes.
            reEnqueueOrphanedRecords()
        }

        // Explicitly trigger fetch — needed on fresh state to pull existing records
        Task {
            do {
                logger.info("[CloudSync] Fetching changes...")
                try await engine.fetchChanges()
                logger.info("[CloudSync] Fetch complete")
                // After a manual reset, find local records CloudKit didn't return and re-upload them.
                reconcileAfterReset()
                // Check for stale placeholders and trigger a recovery fetch if found.
                auditStalePlaceholders()
            } catch {
                logger.error("[CloudSync] Fetch failed: \(error)")
            }
        }
    }

    /// Restart the sync engine from stored state. This forces a fresh fetch
    /// that picks up changes missed due to CKSyncEngine's change token race
    /// (when two devices write to the same zone concurrently).
    func forceResync() {
        logger.info("[CloudSync] Force resync — restarting engine")
        syncEngine = nil
        start()
    }

    /// Wipe the local sync state (change token) and re-download all records
    /// from CloudKit. Use when the local DB is out of sync with the server
    /// (e.g., stuck "Syncing…" placeholder meetings).
    func resetAndResync() {
        logger.info("[CloudSync] Full reset — wiping local data and re-downloading from CloudKit")
        syncEngine = nil
        isResetting = true
        fetchedDuringReset = []

        // Wipe local meetings, segments, and speakers so CloudKit becomes the
        // sole source of truth. Embeddings and FTS are rebuilt by triggers.
        do {
            try db.write { db in
                try db.execute(sql: "DELETE FROM segments")
                try db.execute(sql: "DELETE FROM speakers")
                try db.execute(sql: "DELETE FROM meetings")
            }
            logger.info("[CloudSync] Local data wiped")
        } catch {
            logger.error("[CloudSync] Failed to wipe local data: \(error)")
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
        }

        UserDefaults.standard.removeObject(forKey: stateKey)
        start()
    }

    /// Trigger an immediate fetch from CloudKit — use for pull-to-refresh.
    func fetchNow() async {
        guard let engine = syncEngine else { return }
        do {
            logger.info("[CloudSync] Manual fetch triggered")
            try await engine.fetchChanges()
            logger.info("[CloudSync] Manual fetch complete")
        } catch {
            logger.error("[CloudSync] Manual fetch failed: \(error)")
        }
    }

    // MARK: - Enqueue Helpers

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

    func enqueueDelete(table: String, id: String) {
        guard let engine = syncEngine else { return }
        let recordID = makeRecordID(table: table, id: id)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    fileprivate func refreshSyncCounts() {
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

    func enqueueSaveSegments(meetingId: String) {
        do {
            let segments = try MeetingStore.shared.fetchSegments(forMeeting: meetingId)
            for segment in segments {
                enqueueSave(table: "segments", id: segment.id)
            }
        } catch {
            logger.error("Failed to fetch segments for enqueue: \(error)")
        }
    }

    // MARK: - Initial Upload

    fileprivate func enqueueAllExistingRecords() {
        do {
            let meetings = try MeetingStore.shared.fetchAll()
            for meeting in meetings {
                enqueueSave(table: "meetings", id: meeting.id)
                enqueueSaveSegments(meetingId: meeting.id)
            }
            let speakers: [Speaker] = try db.read { db in try Speaker.fetchAll(db) }
            for speaker in speakers {
                enqueueSave(table: "speakers", id: speaker.id)
            }
            logger.info("Enqueued all existing records for first-launch sync")
        } catch {
            logger.error("Failed to enqueue existing records: \(error)")
        }
    }

    // MARK: - Orphan Re-enqueue

    /// Re-enqueue records that were written to GRDB but never acknowledged by CloudKit.
    /// This happens when the app is killed between the GRDB write and the CloudKit
    /// sentRecordZoneChanges callback. Identified by ckSystemFields == nil on
    /// records that are fully terminal (done/error) and not placeholders.
    fileprivate func reEnqueueOrphanedRecords() {
        do {
            let orphans: [Meeting] = try db.read { db in
                try Meeting
                    .filter(Column("ck_system_fields") == nil)
                    .filter(Column("status") == MeetingStatus.done.rawValue
                         || Column("status") == MeetingStatus.error.rawValue)
                    .filter(Column("title") != "Syncing…")
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

    // MARK: - Placeholder Watchdog

    /// Trigger a fresh fetch if any placeholder meetings are older than 5 minutes.
    /// Placeholders are identified by ckSystemFields == nil and title == "Syncing…".
    /// After 5 minutes without a real parent meeting arriving, the meeting record
    /// likely failed to upload from the originating device. A fetch may pull it in
    /// if it arrived in CloudKit after our last fetch token.
    fileprivate func auditStalePlaceholders() {
        do {
            let cutoff = Date().addingTimeInterval(-300) // 5 minutes
            let stale: [Meeting] = try db.read { db in
                try Meeting
                    .filter(Column("ck_system_fields") == nil)
                    .filter(Column("title") == "Syncing…")
                    .filter(Column("started_at") < cutoff)
                    .fetchAll(db)
            }
            guard !stale.isEmpty else { return }
            logger.warning("[CloudSync] Found \(stale.count) stale placeholder(s) — triggering fetch")
            Task {
                await self.fetchNow()
            }
        } catch {
            logger.error("[CloudSync] Placeholder audit failed: \(error)")
        }
    }

    // MARK: - Post-Reset Reconciliation

    /// After a full reset-and-resync, re-upload local meetings that CloudKit
    /// didn't return. These are records the originating device failed to push
    /// (e.g., killed before acknowledgement). Called once after the reset fetch
    /// completes. Clears the isResetting flag when done.
    fileprivate func reconcileAfterReset() {
        guard isResetting else { return }
        isResetting = false
        let fetched = fetchedDuringReset
        fetchedDuringReset = []

        do {
            let localDone: [Meeting] = try db.read { db in
                try Meeting
                    .filter(Column("status") == MeetingStatus.done.rawValue)
                    .filter(Column("title") != "Syncing…")
                    .fetchAll(db)
            }
            let gap = localDone.filter { !fetched.contains($0.id) }
            guard !gap.isEmpty else {
                logger.info("[CloudSync] Post-reset reconciliation: no gaps found")
                return
            }
            logger.info("[CloudSync] Post-reset reconciliation: re-uploading \(gap.count) missing record(s)")
            for meeting in gap {
                enqueueSave(table: "meetings", id: meeting.id)
                enqueueSaveSegments(meetingId: meeting.id)
            }
        } catch {
            logger.error("[CloudSync] Post-reset reconciliation failed: \(error)")
        }
    }

    // MARK: - State Persistence

    fileprivate func saveState(_ stateSerialization: CKSyncEngine.State.Serialization) {
        do {
            let data = try JSONEncoder().encode(stateSerialization)
            UserDefaults.standard.set(data, forKey: stateKey)
        } catch {
            logger.error("Failed to save sync engine state: \(error)")
        }
    }

    private func restoredState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            logger.error("Failed to decode sync engine state: \(error)")
            return nil
        }
    }

    // MARK: - Record ID Helpers

    fileprivate func makeRecordID(table: String, id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(table)_\(id)", zoneID: zoneID)
    }

    fileprivate func parseRecordID(_ recordID: CKRecord.ID) -> (table: String, id: String)? {
        let name = recordID.recordName
        guard let underscoreIndex = name.firstIndex(of: "_") else { return nil }
        let table = String(name[name.startIndex..<underscoreIndex])
        let id = String(name[name.index(after: underscoreIndex)...])
        guard !table.isEmpty, !id.isEmpty else { return nil }
        return (table, id)
    }

    // MARK: - System Fields

    fileprivate func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private func decodeSystemFields(_ data: Data) -> CKRecord? {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            let record = CKRecord(coder: unarchiver)
            unarchiver.finishDecoding()
            return record
        } catch {
            logger.error("Failed to decode system fields: \(error)")
            return nil
        }
    }

    // MARK: - Record Conversion

    fileprivate func buildRecord(table: String, id: String) -> CKRecord? {
        do {
            switch table {
            case "meetings":
                guard let meeting: Meeting = try db.read({ db in try Meeting.fetchOne(db, key: id) }) else { return nil }
                let record = existingOrNewRecord(type: "Meeting", table: table, id: id, systemFields: meeting.ckSystemFields)
                record["title"] = meeting.title
                record["startedAt"] = meeting.startedAt
                record["endedAt"] = meeting.endedAt
                record["durationSeconds"] = meeting.durationSeconds
                record["status"] = meeting.status.rawValue
                record["summary"] = meeting.summary
                record["actionItems"] = meeting.actionItems
                record["rawTranscript"] = meeting.rawTranscript
                record["calendarEventId"] = meeting.calendarEventId as CKRecordValue?
                record["calendarContext"] = meeting.calendarContext as CKRecordValue?
                return record

            case "segments":
                guard let segment: MeetingSegment = try db.read({ db in try MeetingSegment.fetchOne(db, key: id) }) else { return nil }
                let record = existingOrNewRecord(type: "Segment", table: table, id: id, systemFields: segment.ckSystemFields)
                record["meetingId"] = segment.meetingId
                record["speaker"] = segment.speaker
                record["channel"] = segment.channel
                record["startSeconds"] = segment.startSeconds
                record["endSeconds"] = segment.endSeconds
                record["text"] = segment.text
                return record

            case "speakers":
                guard let speaker: Speaker = try db.read({ db in try Speaker.fetchOne(db, key: id) }) else { return nil }
                let record = existingOrNewRecord(type: "Speaker", table: table, id: id, systemFields: speaker.ckSystemFields)
                record["meetingId"] = speaker.meetingId
                record["label"] = speaker.label
                record["customName"] = speaker.customName
                return record

            default:
                logger.warning("Unknown table: \(table)")
                return nil
            }
        } catch {
            logger.error("Failed to build record for \(table)/\(id): \(error)")
            return nil
        }
    }

    private func existingOrNewRecord(type: String, table: String, id: String, systemFields: Data?) -> CKRecord {
        if let data = systemFields, let record = decodeSystemFields(data) {
            return record
        }
        return CKRecord(recordType: type, recordID: makeRecordID(table: table, id: id))
    }

    // MARK: - Apply Remote Changes

    fileprivate func applyRemoteRecord(_ record: CKRecord) {
        guard let parsed = parseRecordID(record.recordID) else {
            logger.warning("Could not parse record ID: \(record.recordID.recordName)")
            return
        }
        let (table, id) = parsed

        // Track which records arrived from CloudKit during a reset so we can
        // identify local records that CloudKit doesn't have.
        if isResetting && table == "meetings" {
            fetchedDuringReset.insert(id)
        }

        let systemFieldsData = encodeSystemFields(record)

        do {
            switch table {
            case "meetings":
                let meeting = Meeting(
                    id: id,
                    title: record["title"] as? String ?? "Untitled",
                    startedAt: record["startedAt"] as? Date ?? Date(),
                    endedAt: record["endedAt"] as? Date,
                    durationSeconds: record["durationSeconds"] as? Double,
                    status: MeetingStatus(rawValue: record["status"] as? String ?? "done") ?? .done,
                    summary: record["summary"] as? String,
                    actionItems: record["actionItems"] as? String,
                    rawTranscript: record["rawTranscript"] as? String,
                    ckSystemFields: systemFieldsData,
                    calendarEventId: record["calendarEventId"] as? String,
                    calendarContext: record["calendarContext"] as? String
                )
                try db.write { db in
                    if let existing = try Meeting.fetchOne(db, key: id) {
                        var merged = meeting
                        // ckSystemFields: always use remote — it's authoritative CloudKit metadata.
                        // Using stale local system fields causes recordChangeTag conflicts on next upload.
                        merged.ckSystemFields = systemFieldsData

                        // Locally-computed content: keep local if it has a value and remote doesn't.
                        // These fields are written by the transcription/summary pipeline, not by the
                        // recording device at upload time, so they may legitimately be nil on the remote
                        // when a newer local version already has them.
                        merged.summary = existing.summary ?? merged.summary
                        merged.rawTranscript = existing.rawTranscript ?? merged.rawTranscript
                        merged.actionItems = existing.actionItems ?? merged.actionItems

                        // Status: keep local only if it represents more progress than the remote.
                        // This prevents a late-arriving .recording or .transcribing from rolling
                        // back a .done meeting. Skip for placeholders (nil ckSystemFields on existing).
                        if existing.ckSystemFields != nil {
                            let statusOrder: [MeetingStatus] = [.recording, .transcribing, .done, .error]
                            let existingRank = statusOrder.firstIndex(of: existing.status) ?? 0
                            let remoteRank  = statusOrder.firstIndex(of: meeting.status)  ?? 0
                            if existingRank > remoteRank {
                                merged.status = existing.status
                            }
                        }

                        try merged.update(db)
                    } else {
                        try meeting.insert(db)
                    }
                }

            case "segments":
                let meetingId = record["meetingId"] as? String ?? ""
                logger.info("[CloudSync] Applying segment \(id) for meeting \(meetingId)")
                let segment = MeetingSegment(
                    id: id,
                    meetingId: meetingId,
                    speaker: record["speaker"] as? String ?? "",
                    channel: record["channel"] as? String ?? "",
                    startSeconds: record["startSeconds"] as? Double ?? 0,
                    endSeconds: record["endSeconds"] as? Double ?? 0,
                    text: record["text"] as? String ?? "",
                    ckSystemFields: systemFieldsData
                )
                try db.write { db in
                    // Create placeholder meeting if it hasn't arrived yet (FK constraint)
                    if !meetingId.isEmpty, try Meeting.fetchOne(db, key: meetingId) == nil {
                        let placeholder = Meeting(
                            id: meetingId, title: "Syncing…", startedAt: Date(),
                            endedAt: nil, durationSeconds: nil, status: .done,
                            summary: nil, actionItems: nil, rawTranscript: nil,
                            ckSystemFields: nil
                        )
                        try placeholder.insert(db)
                    }
                    if try MeetingSegment.fetchOne(db, key: id) != nil {
                        try segment.update(db)
                        logger.info("[CloudSync] Updated segment \(id)")
                    } else {
                        try segment.insert(db)
                        logger.info("[CloudSync] Inserted segment \(id) for meeting \(meetingId)")
                    }
                }

            case "speakers":
                let meetingId = record["meetingId"] as? String ?? ""
                let speaker = Speaker(
                    id: id,
                    meetingId: meetingId,
                    label: record["label"] as? String ?? "",
                    customName: record["customName"] as? String,
                    ckSystemFields: systemFieldsData
                )
                try db.write { db in
                    // Create placeholder meeting if it hasn't arrived yet (FK constraint)
                    if !meetingId.isEmpty, try Meeting.fetchOne(db, key: meetingId) == nil {
                        let placeholder = Meeting(
                            id: meetingId, title: "Syncing…", startedAt: Date(),
                            endedAt: nil, durationSeconds: nil, status: .done,
                            summary: nil, actionItems: nil, rawTranscript: nil,
                            ckSystemFields: nil
                        )
                        try placeholder.insert(db)
                    }
                    if try Speaker.fetchOne(db, key: id) != nil {
                        try speaker.update(db)
                    } else {
                        try speaker.insert(db)
                    }
                }

            case "audiochunk":
                return  // Handled by RemoteMeetingProcessor polling, not CKSyncEngine

            default:
                logger.warning("Unknown table for remote record: \(table)")
                return
            }

            // Notification batched — posted by fetchedRecordZoneChanges handler
        } catch {
            logger.error("Failed to apply remote record \(table)/\(id): \(error)")
        }
    }

    fileprivate func applyRemoteDeletion(_ recordID: CKRecord.ID) {
        guard let parsed = parseRecordID(recordID) else {
            logger.warning("Could not parse record ID for deletion: \(recordID.recordName)")
            return
        }
        let (table, id) = parsed

        do {
            switch table {
            case "meetings":
                logger.info("[CloudSync] Deleting meeting \(id)")
                try db.write { db in
                    try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
                }
                logger.info("[CloudSync] Meeting deleted: \(id)")
            case "segments":
                try db.write { db in
                    try db.execute(sql: "DELETE FROM segments WHERE id = ?", arguments: [id])
                }
            case "speakers":
                try db.write { db in
                    try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [id])
                }
            case "audiochunk":
                return  // AudioChunks are transient — deletions are expected and ignored

            default:
                logger.warning("Unknown table for deletion: \(table)")
                return
            }

            // Notification batched — posted by fetchedRecordZoneChanges handler
        } catch {
            logger.error("Failed to apply remote deletion \(table)/\(id): \(error)")
        }
    }

    // MARK: - Update System Fields After Successful Save

    fileprivate func updateSystemFields(for record: CKRecord) {
        guard let parsed = parseRecordID(record.recordID) else { return }
        let (table, id) = parsed
        let data = encodeSystemFields(record)

        do {
            switch table {
            case "meetings":
                try db.write { db in
                    try db.execute(sql: "UPDATE meetings SET ck_system_fields = ? WHERE id = ?", arguments: [data, id])
                }
            case "segments":
                try db.write { db in
                    try db.execute(sql: "UPDATE segments SET ck_system_fields = ? WHERE id = ?", arguments: [data, id])
                }
            case "speakers":
                try db.write { db in
                    try db.execute(sql: "UPDATE speakers SET ck_system_fields = ? WHERE id = ?", arguments: [data, id])
                }
            default:
                break
            }
        } catch {
            logger.error("Failed to update system fields for \(table)/\(id): \(error)")
        }
    }
}

// MARK: - SyncDelegate

@available(macOS 14.0, iOS 17.0, *)
private final class SyncDelegate: NSObject, CKSyncEngineDelegate {

    var engine: CloudSyncEngine!

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        engine.logger.info("[CloudSync] Event: \(String(describing: event))")
        switch event {
        case .stateUpdate(let stateUpdate):
            engine.saveState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            engine.logger.info("Account change: \(String(describing: accountChange.changeType))")
            switch accountChange.changeType {
            case .signOut, .switchAccounts:
                // Clear sync state — stale tokens from old account would cause errors
                UserDefaults.standard.removeObject(forKey: engine.stateKey)
                engine.logger.warning("Cleared sync state due to account change")
            default:
                break
            }

        case .fetchedDatabaseChanges(let fetchedChanges):
            for deletion in fetchedChanges.deletions {
                if deletion.zoneID == engine.zoneID {
                    engine.logger.warning("Zone deleted remotely, recreating...")
                    syncEngine.state.add(pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneName: engine.zoneName))
                    ])
                }
            }

        case .fetchedRecordZoneChanges(let fetchedChanges):
            let totalChanges = fetchedChanges.modifications.count + fetchedChanges.deletions.count
            engine.logger.info("[CloudSync] Fetched \(fetchedChanges.modifications.count) modifications, \(fetchedChanges.deletions.count) deletions")
            // Process meetings first so parent rows exist before segments/speakers arrive.
            // This eliminates placeholder creation for intra-batch ordering issues.
            let sortedMods = fetchedChanges.modifications.sorted { a, _ in
                a.record.recordType == "Meeting"
            }
            for modification in sortedMods {
                engine.applyRemoteRecord(modification.record)
            }
            for deletion in fetchedChanges.deletions {
                engine.applyRemoteDeletion(deletion.recordID)
            }
            // Batch notification — one UI refresh for all changes instead of N
            if totalChanges > 0 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                }
            }

        case .sentRecordZoneChanges(let sentChanges):
            for savedRecord in sentChanges.savedRecords {
                engine.updateSystemFields(for: savedRecord)
            }
            for failedSave in sentChanges.failedRecordSaves {
                let recordID = failedSave.record.recordID
                let ckError = failedSave.error

                switch ckError.code {
                case .serverRecordChanged:
                    // Apply server version, then only re-enqueue if local data
                    // actually differs (prevents infinite sync loops)
                    if let serverRecord = ckError.serverRecord {
                        let localRecord = engine.buildRecord(
                            table: engine.parseRecordID(recordID)?.table ?? "",
                            id: engine.parseRecordID(recordID)?.id ?? ""
                        )
                        engine.applyRemoteRecord(serverRecord)
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                        }
                        // Only re-enqueue if local had different content
                        if localRecord != nil {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        }
                    }

                case .zoneNotFound:
                    engine.logger.warning("Zone not found during save, recreating...")
                    syncEngine.state.add(pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneName: engine.zoneName))
                    ])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

                case .unknownItem:
                    // The record was sent as a modify (has a changeTag) but CloudKit
                    // says it doesn't exist. This is authoritative: the record does not
                    // exist on the server. The most likely cause is that it was deleted
                    // on another device and we missed the deletion event. Treat it the
                    // same as a received deletion — remove the local row. If another
                    // device still has the record and it should exist, it will re-upload it.
                    engine.logger.warning("[CloudSync] Unknown item — treating as remote deletion: \(recordID.recordName)")
                    engine.applyRemoteDeletion(recordID)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                    }

                default:
                    engine.logger.error("Record save failed (\(ckError.code.rawValue)): \(ckError.localizedDescription)")
                }
            }

        case .sentDatabaseChanges(let sentChanges):
            for failedSave in sentChanges.failedZoneSaves {
                engine.logger.error("Zone save failed: \(failedSave.error.localizedDescription)")
            }

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            engine.logger.info("Unknown sync engine event")
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { change in
            scope.contains(change)
        }

        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
            guard let parsed = self.engine.parseRecordID(recordID) else { return nil }
            return self.engine.buildRecord(table: parsed.table, id: parsed.id)
        }
    }
}
