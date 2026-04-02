import CloudKit
import Foundation
import GRDB
import os

// MARK: - CloudSyncEngine

@available(macOS 14.0, iOS 17.0, *)
final class CloudSyncEngine: ObservableObject {

    static let shared = CloudSyncEngine()

    fileprivate lazy var container: CKContainer = CKContainer(identifier: "iCloud.com.memgram.app")
    fileprivate let zoneName = "MemgramZone"
    fileprivate let stateKey = "CKSyncEngineState"
    fileprivate let logger = Logger.make("CloudSync")
    let db: AppDatabase

    fileprivate var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }

    nonisolated(unsafe) var transport: (any SyncTransport)?

    @Published var uploadingIds: Set<String> = []
    @Published var pendingCount: Int = 0
    @Published var failedCount: Int = 0

    private init() {
        self.db = AppDatabase.shared
        self.transport = nil  // created in start()
    }

    init(db: AppDatabase, transport: any SyncTransport) {
        self.db = db
        self.transport = transport
        transport.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        let isFirstLaunch = UserDefaults.standard.data(forKey: stateKey) == nil
        logger.info("[CloudSync] Starting. isFirstLaunch=\(isFirstLaunch)")

        let ckTransport = CKSyncTransport(
            container: container,
            zoneID: zoneID,
            stateKey: stateKey
        )
        ckTransport.delegate = self
        ckTransport.start()
        self.transport = ckTransport

        logger.info("[CloudSync] Engine created")

        // Ensure zone exists via CKSyncEngine (not direct API)
        ckTransport.ensureZone(zoneID)

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
                try await ckTransport.fetchChanges()
                let postFetchCounts = self.dbCounts()
                logger.info("[CloudSync] Fetch complete — DB now has \(postFetchCounts.meetings) meetings, \(postFetchCounts.segments) segments, \(postFetchCounts.placeholders) placeholders")
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
        transport = nil
        start()
    }

    /// Wipe the local sync state (change token) and re-download all records
    /// from CloudKit. Use when the local DB is out of sync with the server
    /// (e.g., stuck "Syncing…" placeholder meetings).
    func resetAndResync() {
        let preCounts = dbCounts()
        logger.info("[CloudSync] Full reset — wiping local data (\(preCounts.meetings) meetings, \(preCounts.segments) segments) and re-downloading from CloudKit")
        transport = nil

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
        guard let transport else { return }
        do {
            logger.info("[CloudSync] Manual fetch triggered")
            try await transport.fetchChanges()
            logger.info("[CloudSync] Manual fetch complete")
        } catch {
            logger.error("[CloudSync] Manual fetch failed: \(error)")
        }
    }

    // MARK: - Enqueue Helpers

    func enqueueSave(table: String, id: String) {
        // Always persist pendingUpload to DB for meetings — even if the sync engine
        // isn't running yet. reEnqueueOrphanedRecords picks this up on next launch.
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
            DispatchQueue.main.async { self.uploadingIds.insert(id) }
        }
        guard let transport else { return }
        let recordID = makeRecordID(table: table, id: id)
        transport.enqueueSave(recordID)
        logger.info("[CloudSync] Enqueued \(table)/\(id) for upload")
    }

    func enqueueDelete(table: String, id: String) {
        guard let transport else { return }
        let recordID = makeRecordID(table: table, id: id)
        transport.enqueueDelete(recordID)
    }

    fileprivate func refreshSyncCounts() {
        do {
            var pending = 0
            var failed  = 0
            try db.read { db in
                pending = try Meeting
                    .filter(Column("sync_status") == SyncStatus.pendingUpload.rawValue)
                    .fetchCount(db)
                failed = try Meeting
                    .filter(Column("sync_status") == SyncStatus.failed.rawValue)
                    .fetchCount(db)
            }
            DispatchQueue.main.async { [weak self] in
                self?.pendingCount = pending
                self?.failedCount  = failed
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
            logger.info("[CloudSync] Enqueued all existing records for first-launch sync — \(meetings.count) meetings, \(speakers.count) speakers")
        } catch {
            logger.error("Failed to enqueue existing records: \(error)")
        }
    }

    // MARK: - Orphan Re-enqueue

    fileprivate func reEnqueueOrphanedRecords() {
        do {
            let orphans: [Meeting] = try db.read { db in
                try Meeting
                    .filter(Column("sync_status") == SyncStatus.pendingUpload.rawValue
                         || Column("sync_status") == SyncStatus.failed.rawValue)
                    .fetchAll(db)
            }
            guard !orphans.isEmpty else { return }
            logger.info("[CloudSync] Re-enqueuing \(orphans.count) orphaned/failed local records")
            for meeting in orphans {
                enqueueSave(table: "meetings", id: meeting.id)
                enqueueSaveSegments(meetingId: meeting.id)
            }
        } catch {
            logger.error("[CloudSync] Failed to re-enqueue orphaned records: \(error)")
        }
    }

    // MARK: - Placeholder Watchdog

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

    // MARK: - Record Comparison

    /// Compare two CKRecords field-by-field for the synced fields.
    /// Used to avoid re-enqueueing identical data after a conflict resolution.
    fileprivate func recordsMatch(_ a: CKRecord, _ b: CKRecord, table: String) -> Bool {
        switch table {
        case "meetings":
            return a["title"] as? String == b["title"] as? String
                && a["status"] as? String == b["status"] as? String
                && a["summary"] as? String == b["summary"] as? String
                && a["rawTranscript"] as? String == b["rawTranscript"] as? String
                && a["actionItems"] as? String == b["actionItems"] as? String
        case "segments":
            return a["text"] as? String == b["text"] as? String
                && a["speaker"] as? String == b["speaker"] as? String
        case "speakers":
            return a["label"] as? String == b["label"] as? String
                && a["customName"] as? String == b["customName"] as? String
        default:
            return false
        }
    }

    // MARK: - Diagnostic Helpers

    fileprivate func dbCounts() -> (meetings: Int, segments: Int, placeholders: Int) {
        do {
            return try db.read { db in
                let meetings = try Meeting.fetchCount(db)
                let segments = try MeetingSegment.fetchCount(db)
                let placeholders = try Meeting
                    .filter(Column("sync_status") == SyncStatus.placeholder.rawValue)
                    .fetchCount(db)
                return (meetings, segments, placeholders)
            }
        } catch {
            return (0, 0, 0)
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

    fileprivate func buildCKRecord(table: String, id: String) -> CKRecord? {
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
                logger.info("[CloudSync] Built record meetings/\(id) (\(meeting.ckSystemFields != nil ? "has systemFields" : "new"))")
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
                logger.info("[CloudSync] Built record segments/\(id)")
                return record

            case "speakers":
                guard let speaker: Speaker = try db.read({ db in try Speaker.fetchOne(db, key: id) }) else { return nil }
                let record = existingOrNewRecord(type: "Speaker", table: table, id: id, systemFields: speaker.ckSystemFields)
                record["meetingId"] = speaker.meetingId
                record["label"] = speaker.label
                record["customName"] = speaker.customName
                logger.info("[CloudSync] Built record speakers/\(id)")
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

        let systemFieldsData = encodeSystemFields(record)

        do {
            switch table {
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
                var wasInsert = false
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
                        wasInsert = true
                        try meeting.insert(db)
                    }
                }
                logger.info("[CloudSync] Applied meeting \(id) — \(wasInsert ? "inserted" : "updated") — status \(meeting.status.rawValue)")

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
                            syncStatus: .placeholder,
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
                            syncStatus: .placeholder,
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

            // Notification batched — posted by didReceive handler
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

            // Notification batched — posted by didReceive handler
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
}

// MARK: - SyncTransportDelegate

@available(macOS 14.0, iOS 17.0, *)
extension CloudSyncEngine: SyncTransportDelegate {

    func buildRecord(table: String, id: String) -> CKRecord? {
        buildCKRecord(table: table, id: id)
    }

    func didSend(saved: [CKRecord], failed: [(record: CKRecord, error: CKError)]) {
        for savedRecord in saved {
            if let parsed = parseRecordID(savedRecord.recordID) {
                logger.info("[CloudSync] Uploaded \(parsed.table)/\(parsed.id) successfully")
            }
            updateSystemFields(for: savedRecord)
        }

        for failedSave in failed {
            let recordID = failedSave.record.recordID
            let ckError = failedSave.error

            switch ckError.code {
            case .serverRecordChanged:
                logger.warning("[CloudSync] Upload conflict for \(recordID.recordName) — applying server version")
                if let serverRecord = ckError.serverRecord,
                   let parsed = parseRecordID(recordID) {
                    applyRemoteRecord(serverRecord)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                    }
                    // Re-enqueue only if the merged local record differs from
                    // the server version (e.g. local has a summary the server lacks).
                    // Comparing the rebuilt record prevents infinite sync loops.
                    let mergedRecord = buildCKRecord(table: parsed.table, id: parsed.id)
                    if let merged = mergedRecord, !recordsMatch(merged, serverRecord, table: parsed.table) {
                        logger.info("[CloudSync] Local data differs from server for \(parsed.table)/\(parsed.id) — re-enqueueing")
                        enqueueSave(table: parsed.table, id: parsed.id)
                    }
                }
                // Remove from uploadingIds — the record will re-enter when the retry batch fires
                if let parsed = parseRecordID(recordID), parsed.table == "meetings" {
                    DispatchQueue.main.async { [weak self] in self?.uploadingIds.remove(parsed.id) }
                }

            case .zoneNotFound:
                logger.warning("[CloudSync] Upload failed for \(recordID.recordName) — zone not found, recreating")
                transport?.ensureZone(zoneID)
                transport?.enqueueSave(recordID)

            case .unknownItem:
                // The record was sent as a modify (has a changeTag) but CloudKit
                // says it doesn't exist. Treat as remote deletion.
                logger.warning("[CloudSync] Unknown item — treating as remote deletion: \(recordID.recordName)")
                applyRemoteDeletion(recordID)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                }

            default:
                logger.error("[CloudSync] Upload failed for \(recordID.recordName) — code \(ckError.code.rawValue): \(ckError.localizedDescription)")
                if let parsed = parseRecordID(recordID), parsed.table == "meetings" {
                    do {
                        try db.write { db in
                            try db.execute(
                                sql: "UPDATE meetings SET sync_status = ? WHERE id = ?",
                                arguments: [SyncStatus.failed.rawValue, parsed.id]
                            )
                        }
                        DispatchQueue.main.async { [weak self] in self?.uploadingIds.remove(parsed.id) }
                        refreshSyncCounts()
                    } catch {
                        logger.error("Failed to set .failed for meeting \(parsed.id): \(error)")
                    }
                }
            }
        }
    }

    func didReceive(modifications: [CKRecord], deletions: [CKRecord.ID]) {
        let totalChanges = modifications.count + deletions.count
        logger.info("[CloudSync] Fetched \(modifications.count) modifications, \(deletions.count) deletions")

        for record in modifications {
            applyRemoteRecord(record)
        }
        for recordID in deletions {
            applyRemoteDeletion(recordID)
        }

        // Batch notification — one UI refresh for all changes instead of N
        if totalChanges > 0 {
            refreshSyncCounts()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            }
        }
    }

    func didSaveState(_ data: Data) {
        // State persistence is handled by CKSyncTransport directly.
        // This callback is available for tests or additional state tracking.
    }
}
