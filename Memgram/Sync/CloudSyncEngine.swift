import CloudKit
import Foundation
import GRDB
import os

// MARK: - CloudSyncEngine

@available(macOS 14.0, iOS 17.0, *)
final class CloudSyncEngine: Sendable {

    static let shared = CloudSyncEngine()

    fileprivate let container = CKContainer(identifier: "iCloud.com.memgram.app")
    fileprivate let zoneName = "MemgramZone"
    fileprivate let stateKey = "CKSyncEngineState"
    fileprivate let logger = Logger(subsystem: "com.memgram.app", category: "CloudSync")
    fileprivate let db = AppDatabase.shared

    fileprivate var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }

    nonisolated(unsafe) private var syncEngine: CKSyncEngine?
    private let delegate: SyncDelegate

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
        }

        // Explicitly trigger fetch — needed on fresh state to pull existing records
        Task {
            do {
                logger.info("[CloudSync] Fetching changes...")
                try await engine.fetchChanges()
                logger.info("[CloudSync] Fetch complete")
            } catch {
                logger.error("[CloudSync] Fetch failed: \(error)")
            }
        }
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
    }

    func enqueueDelete(table: String, id: String) {
        guard let engine = syncEngine else { return }
        let recordID = makeRecordID(table: table, id: id)
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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
                    if try Meeting.fetchOne(db, key: id) != nil {
                        try meeting.update(db)
                    } else {
                        try meeting.insert(db)
                    }
                }

            case "segments":
                let meetingId = record["meetingId"] as? String ?? ""
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
                    } else {
                        try segment.insert(db)
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

            default:
                logger.warning("Unknown table for remote record: \(table)")
                return
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            }
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
                try db.write { db in
                    try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
                }
            case "segments":
                try db.write { db in
                    try db.execute(sql: "DELETE FROM segments WHERE id = ?", arguments: [id])
                }
            case "speakers":
                try db.write { db in
                    try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [id])
                }
            default:
                logger.warning("Unknown table for deletion: \(table)")
                return
            }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            }
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
            engine.logger.info("[CloudSync] Fetched \(fetchedChanges.modifications.count) modifications, \(fetchedChanges.deletions.count) deletions")
            for modification in fetchedChanges.modifications {
                engine.applyRemoteRecord(modification.record)
            }
            for deletion in fetchedChanges.deletions {
                engine.applyRemoteDeletion(deletion.recordID)
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
                    if let serverRecord = ckError.serverRecord {
                        engine.applyRemoteRecord(serverRecord)
                    }
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

                case .zoneNotFound:
                    engine.logger.warning("Zone not found during save, recreating...")
                    syncEngine.state.add(pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneName: engine.zoneName))
                    ])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

                case .unknownItem:
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

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
