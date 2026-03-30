import CloudKit
import Foundation
import OSLog

/// Direct CloudKit operations for transient audio chunks.
/// Audio chunks bypass CKSyncEngine — they are uploaded, processed, and deleted.
final class AudioChunkService {
    static let shared = AudioChunkService()

    private let log = Logger.make("AudioChunk")
    private let container = CKContainer(identifier: "iCloud.com.memgram.app")
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "MemgramZone")

    private init() {}

    static let recordType = "AudioChunk"

    /// Create a CKRecord for an audio chunk with a CKAsset.
    func makeChunkRecord(meetingId: String, chunkIndex: Int, offsetSeconds: Double, audioFileURL: URL) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "audiochunk_\(meetingId)_\(chunkIndex)", zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["meetingId"] = meetingId as CKRecordValue
        record["chunkIndex"] = chunkIndex as CKRecordValue
        record["offsetSeconds"] = offsetSeconds as CKRecordValue
        record["status"] = "pending" as CKRecordValue
        record["audioData"] = CKAsset(fileURL: audioFileURL)
        return record
    }

    /// Upload a single audio chunk record.
    func upload(record: CKRecord) async throws {
        log.info("Uploading chunk: \(record.recordID.recordName, privacy: .public)")
        let (_, results) = try await database.modifyRecords(saving: [record], deleting: [])
        for (_, result) in results {
            if case .failure(let error) = result {
                throw error
            }
        }
        log.info("Chunk uploaded: \(record.recordID.recordName, privacy: .public)")
    }

    /// Fetch all pending audio chunks for a given meeting, ordered by chunkIndex.
    func fetchPendingChunks(meetingId: String) async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "meetingId == %@ AND status == %@", meetingId, "pending")
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "chunkIndex", ascending: true)]
        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        return try results.map { try $0.1.get() }
    }

    /// Fetch ALL pending audio chunks across all meetings.
    func fetchAllPendingChunks() async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "status == %@", "pending")
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "chunkIndex", ascending: true)]
        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        return try results.map { try $0.1.get() }
    }

    /// Atomically claim a chunk by updating status from "pending" → "processing".
    /// Uses ifServerRecordUnchanged so only one Mac wins the race.
    /// Returns true if this Mac claimed it, false if another Mac got there first.
    func claimChunk(_ record: CKRecord) async -> Bool {
        record["status"] = "processing" as CKRecordValue
        do {
            let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            op.savePolicy = .ifServerRecordUnchanged
            op.qualityOfService = .userInitiated
            try await database.modifyRecords(saving: [record], deleting: [])
            log.info("Claimed chunk: \(record.recordID.recordName, privacy: .public)")
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            log.info("Chunk already claimed by another Mac: \(record.recordID.recordName, privacy: .public)")
            return false
        } catch {
            log.error("Claim failed for chunk \(record.recordID.recordName, privacy: .public): \(error)")
            return false
        }
    }

    /// Delete a processed audio chunk record (removes CKAsset from iCloud storage).
    func markDoneAndDelete(recordID: CKRecord.ID) async throws {
        log.info("Deleting processed chunk: \(recordID.recordName, privacy: .public)")
        let (_, results) = try await database.modifyRecords(saving: [], deleting: [recordID])
        for (_, result) in results {
            if case .failure(let error) = result {
                throw error
            }
        }
        log.info("Chunk deleted: \(recordID.recordName, privacy: .public)")
    }

    /// Download the audio asset from a chunk record to a local temp file.
    func downloadAudioAsset(from record: CKRecord) throws -> URL? {
        guard let asset = record["audioData"] as? CKAsset,
              let assetURL = asset.fileURL else {
            log.warning("No audio asset in chunk: \(record.recordID.recordName, privacy: .public)")
            return nil
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiochunk_\(UUID().uuidString).raw")
        try FileManager.default.copyItem(at: assetURL, to: tempURL)
        return tempURL
    }
}
