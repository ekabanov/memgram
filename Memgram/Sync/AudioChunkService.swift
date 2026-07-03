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

    /// Find chunks stuck in "processing" and reset them to "pending".
    /// - Parameter maxAge: Only reset chunks that have been "processing" longer than this.
    ///   Never pass 0 blindly — resetting fresh claims steals chunks another Mac
    ///   is actively transcribing and produces duplicated transcript text.
    func resetStuckProcessingChunks(olderThan maxAge: TimeInterval) async throws -> Int {
        let predicate: NSPredicate
        if maxAge > 0 {
            let cutoff = Date().addingTimeInterval(-maxAge)
            predicate = NSPredicate(format: "status == %@ AND modificationDate < %@", "processing", cutoff as NSDate)
        } else {
            predicate = NSPredicate(format: "status == %@", "processing")
        }
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        let stuck = try await fetchAll(matching: query)
        guard !stuck.isEmpty else { return 0 }
        for record in stuck {
            record["status"] = "pending" as CKRecordValue
        }
        // Batch save; per-record conflicts (another Mac raced us) are skipped, not fatal.
        let (saveResults, _) = try await database.modifyRecords(saving: stuck, deleting: [], atomically: false)
        var reset = 0
        for (recordID, result) in saveResults {
            switch result {
            case .success:
                reset += 1
            case .failure(let error):
                if let ck = error as? CKError, ck.code == .serverRecordChanged {
                    log.info("Skipped stuck-chunk reset (another Mac won): \(recordID.recordName)")
                } else {
                    log.error("Stuck-chunk reset failed for \(recordID.recordName): \(error)")
                }
            }
        }
        return reset
    }

    /// Run a CKQuery to exhaustion, following cursors across server page limits.
    private func fetchAll(matching query: CKQuery) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var (results, cursor) = try await database.records(matching: query, inZoneWith: zoneID)
        records += try results.map { try $0.1.get() }
        while let next = cursor {
            (results, cursor) = try await database.records(continuingMatchFrom: next)
            records += try results.map { try $0.1.get() }
        }
        return records
    }

    /// Fetch all unfinished chunks (pending OR processing) for a meeting.
    /// Used to check whether a meeting is truly done — no chunks in any state.
    func fetchUnfinishedChunks(meetingId: String) async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "meetingId == %@ AND (status == %@ OR status == %@)",
                                    meetingId, "pending", "processing")
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        return try await fetchAll(matching: query)
    }

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
        log.info("Uploading chunk: \(record.recordID.recordName)")
        let (_, results) = try await database.modifyRecords(saving: [record], deleting: [])
        for (_, result) in results {
            if case .failure(let error) = result {
                throw error
            }
        }
        log.info("Chunk uploaded: \(record.recordID.recordName)")
    }

    /// Fetch all pending audio chunks for a given meeting, ordered by chunkIndex.
    func fetchPendingChunks(meetingId: String) async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "meetingId == %@ AND status == %@", meetingId, "pending")
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "chunkIndex", ascending: true)]
        return try await fetchAll(matching: query)
    }

    /// Fetch ALL pending audio chunks across all meetings.
    func fetchAllPendingChunks() async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "status == %@", "pending")
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "chunkIndex", ascending: true)]
        return try await fetchAll(matching: query)
    }

    /// Atomically claim a chunk by updating status from "pending" → "processing".
    /// Relies on the default `.ifServerRecordUnchanged` save policy so only one
    /// Mac wins the race. Per-record failures arrive in the results dictionary
    /// (not as a thrown error), so they must be checked explicitly.
    /// Returns the saved record (carrying the fresh change tag — required for any
    /// follow-up CAS save like release/markFailed), or nil if another Mac won.
    func claimChunk(_ record: CKRecord) async -> CKRecord? {
        record["status"] = "processing" as CKRecordValue
        do {
            let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [])
            var saved: CKRecord?
            for (_, result) in saveResults {
                switch result {
                case .success(let serverRecord):
                    saved = serverRecord
                case .failure(let error):
                    if let ck = error as? CKError, ck.code == .serverRecordChanged {
                        log.info("Chunk already claimed by another Mac: \(record.recordID.recordName)")
                    } else {
                        log.error("Claim failed for chunk \(record.recordID.recordName): \(error)")
                    }
                    return nil
                }
            }
            log.info("Claimed chunk: \(record.recordID.recordName)")
            return saved ?? record
        } catch let error as CKError where error.code == .serverRecordChanged {
            log.info("Chunk already claimed by another Mac: \(record.recordID.recordName)")
            return nil
        } catch {
            log.error("Claim failed for chunk \(record.recordID.recordName): \(error)")
            return nil
        }
    }

    /// Release a claimed chunk back to "pending" so it is retried on the next poll.
    func releaseChunk(_ record: CKRecord) async {
        record["status"] = "pending" as CKRecordValue
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [])
        } catch {
            log.error("Release failed for chunk \(record.recordID.recordName): \(error) — staleness reset will recover it")
        }
    }

    /// Mark a chunk permanently failed so it stops blocking meeting finalization
    /// (fetchUnfinishedChunks only matches pending/processing). The record is kept
    /// for diagnosis and cleaned up by deleteRemainingChunks on finalization.
    func markFailed(_ record: CKRecord) async {
        record["status"] = "failed" as CKRecordValue
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [])
            log.warning("Chunk marked failed: \(record.recordID.recordName)")
        } catch {
            log.error("markFailed failed for chunk \(record.recordID.recordName): \(error)")
        }
    }

    /// Delete all remaining chunk records (e.g. "failed" leftovers) for a finalized meeting.
    func deleteRemainingChunks(meetingId: String) async {
        do {
            let predicate = NSPredicate(format: "meetingId == %@", meetingId)
            let query = CKQuery(recordType: Self.recordType, predicate: predicate)
            let leftovers = try await fetchAll(matching: query)
            guard !leftovers.isEmpty else { return }
            _ = try await database.modifyRecords(saving: [], deleting: leftovers.map(\.recordID))
            log.info("Deleted \(leftovers.count) leftover chunk record(s) for meeting \(meetingId)")
        } catch {
            log.error("Leftover chunk cleanup failed for meeting \(meetingId): \(error)")
        }
    }

    /// Record type for cross-Mac work claims (finalization, summarization).
    /// One shared type keeps the CloudKit production schema footprint minimal.
    static let claimRecordType = "ProcessingClaim"

    /// Atomically claim the right to finalize a meeting across Macs.
    /// A claim untouched for 10 minutes is presumed abandoned (Mac slept or
    /// crashed mid-finalize) and can be stolen.
    func claimFinalization(meetingId: String) async -> Bool {
        await claimWork(kind: "finalize", meetingId: meetingId, staleAfter: 10 * 60)
    }

    /// Atomically claim the right to summarize a meeting across Macs.
    /// Local LLM summaries can take a while, so the steal window is longer.
    func claimSummarization(meetingId: String) async -> Bool {
        await claimWork(kind: "summarize", meetingId: meetingId, staleAfter: 15 * 60)
    }

    /// Claim a unit of cross-Mac work by creating a marker record — the first Mac
    /// to create it wins. A claim whose record hasn't been touched for `staleAfter`
    /// is presumed abandoned (Macs are unreliable and sleep mid-work) and can be
    /// stolen via a CAS re-save. Fails CLOSED only on an explicit "record already
    /// exists" conflict; any other error (e.g. the record type not yet deployed to
    /// the production CloudKit schema) fails OPEN so the work still happens.
    private func claimWork(kind: String, meetingId: String, staleAfter: TimeInterval) async -> Bool {
        let recordID = CKRecord.ID(recordName: "\(kind)_\(meetingId)", zoneID: zoneID)
        let record = CKRecord(recordType: Self.claimRecordType, recordID: recordID)
        record["meetingId"] = meetingId as CKRecordValue
        do {
            let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [])
            for (_, result) in saveResults {
                if case .failure(let error) = result {
                    return await resolveClaimConflict(error, kind: kind, meetingId: meetingId, staleAfter: staleAfter)
                }
            }
            log.info("Claimed \(kind) for meeting \(meetingId)")
            return true
        } catch {
            return await resolveClaimConflict(error, kind: kind, meetingId: meetingId, staleAfter: staleAfter)
        }
    }

    private func resolveClaimConflict(_ error: Error, kind: String, meetingId: String, staleAfter: TimeInterval) async -> Bool {
        guard let ck = error as? CKError, ck.code == .serverRecordChanged else {
            log.error("\(kind) claim errored for meeting \(meetingId) — proceeding anyway: \(error)")
            return true
        }
        // Claim already exists. Steal it only if it looks abandoned.
        guard let server = ck.serverRecord,
              let modified = server.modificationDate,
              Date().timeIntervalSince(modified) > staleAfter else {
            log.info("\(kind) already claimed by another Mac for meeting \(meetingId)")
            return false
        }
        // CAS re-save: only one Mac wins the steal race.
        server["meetingId"] = meetingId as CKRecordValue
        do {
            let (saveResults, _) = try await database.modifyRecords(saving: [server], deleting: [])
            for (_, result) in saveResults {
                if case .failure = result { return false }
            }
            log.warning("Stole stale \(kind) claim for meeting \(meetingId)")
            return true
        } catch {
            return false
        }
    }

    /// Delete a processed audio chunk record (removes CKAsset from iCloud storage).
    func markDoneAndDelete(recordID: CKRecord.ID) async throws {
        log.info("Deleting processed chunk: \(recordID.recordName)")
        let (_, results) = try await database.modifyRecords(saving: [], deleting: [recordID])
        for (_, result) in results {
            if case .failure(let error) = result {
                throw error
            }
        }
        log.info("Chunk deleted: \(recordID.recordName)")
    }

    /// Download the audio asset from a chunk record to a local temp file.
    func downloadAudioAsset(from record: CKRecord) throws -> URL? {
        guard let asset = record["audioData"] as? CKAsset,
              let assetURL = asset.fileURL else {
            log.warning("No audio asset in chunk: \(record.recordID.recordName)")
            return nil
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiochunk_\(UUID().uuidString).raw")
        try FileManager.default.copyItem(at: assetURL, to: tempURL)
        return tempURL
    }
}
