import CloudKit
import Foundation
@testable import Memgram

/// Test implementation of SyncTransport backed by a FakeCloudKitChannel.
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
