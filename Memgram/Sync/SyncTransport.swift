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
