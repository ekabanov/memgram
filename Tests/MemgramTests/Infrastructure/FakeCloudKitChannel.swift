import CloudKit
import Foundation
@testable import Memgram

/// In-memory iCloud backend for tests.
/// Stores CKRecords, tracks versions for conflict detection,
/// and simulates push notifications between connected transports.
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
