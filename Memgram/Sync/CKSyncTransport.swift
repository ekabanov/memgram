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

        case .accountChange(let accountChange):
            logger.info("Account change: \(String(describing: accountChange.changeType))")
            switch accountChange.changeType {
            case .signOut, .switchAccounts:
                UserDefaults.standard.removeObject(forKey: stateKey)
                logger.warning("Cleared sync state due to account change")
            default:
                break
            }

        case .fetchedRecordZoneChanges(let fetchedChanges):
            // Sort meetings first so parent rows exist before segments/speakers
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

        case .sentDatabaseChanges(let sentChanges):
            for failedSave in sentChanges.failedZoneSaves {
                logger.error("Zone save failed: \(failedSave.error.localizedDescription)")
            }

        case .fetchedDatabaseChanges(let dbChanges):
            for deletion in dbChanges.deletions {
                if deletion.zoneID.zoneName == zoneID.zoneName {
                    logger.warning("Zone deleted — recreating")
                    ensureZone(zoneID)
                }
            }

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

        logger.info("[CKSyncTransport] Sending batch of \(pendingChanges.count) records")

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
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
            delegate?.didSaveState(data)
        } catch {
            logger.error("Failed to save sync state: \(error)")
        }
    }

    private func restoredState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }
}
