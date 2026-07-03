import Testing
import CloudKit
import Foundation
import GRDB
@testable import Memgram

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

    @Test func unknownItemOnSaveRecreatesInsteadOfDeleting() throws {
        // The server losing a record we believe is synced (dev-env wipe,
        // container reset) must NEVER delete local data — the record is
        // re-uploaded as a fresh create. Regression test for a real data-loss
        // incident: a freshly summarized meeting vanished from the list.
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Precious")

        // Sync once so the local record carries CKRecord system fields
        env.transport.flush()
        try env.meetingStore.saveSummary(meetingId: meeting.id, summary: "Important summary")

        // Server "loses" the record: next save fails with unknownItem
        channel.failNextSave = .unknownItem
        env.transport.flush()

        // Meeting must still exist locally, queued for a fresh upload
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)
        #expect(fetched != nil)
        #expect(fetched?.summary == "Important summary")
        #expect(fetched?.syncStatus == .pendingUpload)
        #expect(fetched?.ckSystemFields == nil)

        // Next flush re-creates it on the server
        env.transport.flush()
        let resynced = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(resynced.syncStatus == .synced)
        #expect(channel.records["meetings_\(meeting.id)"] != nil)
    }

    @Test func serverRecordChangedAppliesRemoteWithoutReenqueueWhenIdentical() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Original")

        // First sync to establish the record in the channel
        env.transport.flush()

        // Simulate another device updating the title in the channel
        let key = "meetings_\(meeting.id)"
        if let serverRecord = channel.records[key] {
            serverRecord["title"] = "Remote Title" as CKRecordValue
        }

        // Now update locally and mark as conflicting
        try env.meetingStore.updateTitle(meeting.id, title: "Local Title")
        channel.conflictingRecordIDs.insert(key)

        // Flush — should get serverRecordChanged
        env.transport.flush()

        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        // Remote title wins; merged record now matches the server, so no
        // re-enqueue happens (prevents infinite conflict loops) and the
        // record settles as synced.
        #expect(fetched.title == "Remote Title")
        #expect(fetched.syncStatus == .synced)
    }

    @Test func serverRecordChangedReenqueuesWhenLocalDataDiffers() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Original")

        // First sync to establish the record in the channel
        env.transport.flush()

        // Simulate another device updating the title in the channel
        let key = "meetings_\(meeting.id)"
        if let serverRecord = channel.records[key] {
            serverRecord["title"] = "Remote Title" as CKRecordValue
        }

        // Local gains a summary the server lacks, then conflicts on upload
        try env.meetingStore.saveSummary(meetingId: meeting.id, summary: "Local summary")
        channel.conflictingRecordIDs.insert(key)

        // Flush — serverRecordChanged; local summary survives the merge,
        // so the merged record differs from the server and is re-enqueued.
        env.transport.flush()

        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.summary == "Local summary")
        #expect(fetched.syncStatus == .pendingUpload)
    }

    // MARK: - applyRemoteRecord normalization

    @Test func remoteRecordNormalizesInterrupted() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)

        // Simulate a record arriving via transport (routes through didReceive -> applyRemoteRecord)
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

    @Test func remoteDoneOverridesLocalError() throws {
        // If another Mac successfully finalized the meeting, its .done (with
        // transcript) must replace a local failure state — .error outranking
        // .done would block convergence forever.
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Flaky Start")

        // First sync so the local record has ckSystemFields (merge rank applies)
        env.transport.flush()
        try env.meetingStore.updateStatus(meeting.id, status: .error)

        let zoneID = CKRecordZone.ID(zoneName: "MemgramZone")
        let recordID = CKRecord.ID(recordName: "meetings_\(meeting.id)", zoneID: zoneID)
        let record = CKRecord(recordType: "Meeting", recordID: recordID)
        record["title"] = "Flaky Start" as CKRecordValue
        record["startedAt"] = meeting.startedAt as CKRecordValue
        record["status"] = "done" as CKRecordValue
        record["rawTranscript"] = "Recovered transcript" as CKRecordValue

        env.transport.receive(modifications: [record], deletions: [])

        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.status == .done)
        #expect(fetched.rawTranscript == "Recovered transcript")
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

        // Route through transport -> didReceive -> applyRemoteRecord
        env.transport.receive(modifications: [segmentRecord], deletions: [])

        let placeholder = try env.meetingStore.fetchMeeting(meetingId)!
        #expect(placeholder.syncStatus == .placeholder)
        #expect(placeholder.title == "Syncing\u{2026}")
    }

    @Test func appendRemoteSegmentCreatesPlaceholderForUnknownMeeting() throws {
        // The chunk pipeline can deliver transcribed segments before the meeting
        // record has synced. appendRemoteSegment must create a placeholder meeting
        // instead of letting the FK constraint destroy the transcript.
        let env = try TestSyncEnvironment.makeLocal()

        let meetingId = UUID().uuidString
        let segment = MeetingSegment(
            id: UUID().uuidString,
            meetingId: meetingId,
            speaker: "Remote",
            channel: "system",
            startSeconds: 0,
            endSeconds: 10,
            text: "Hello from a chunk"
        )

        try env.meetingStore.appendRemoteSegment(segment)

        let placeholder = try env.meetingStore.fetchMeeting(meetingId)!
        #expect(placeholder.syncStatus == .placeholder)
        let segments = try env.meetingStore.fetchSegments(forMeeting: meetingId)
        #expect(segments.count == 1)
        #expect(segments.first?.text == "Hello from a chunk")
    }

    @Test func appendRemoteSegmentUsesExistingMeeting() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Real Meeting")

        let segment = MeetingSegment(
            id: UUID().uuidString,
            meetingId: meeting.id,
            speaker: "You",
            channel: "mic",
            startSeconds: 0,
            endSeconds: 5,
            text: "Hi"
        )
        try env.meetingStore.appendRemoteSegment(segment)

        // No placeholder overwrite — the real meeting is untouched
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.title == "Real Meeting")
        #expect(fetched.syncStatus != .placeholder)
        #expect(try env.meetingStore.fetchSegments(forMeeting: meeting.id).count == 1)
    }

    // MARK: - Startup recovery

    @Test func orphanedPendingUploadSyncsAfterReEnqueue() throws {
        let channel = FakeCloudKitChannel()
        let env = try TestSyncEnvironment.make(channel: channel)
        let meeting = try env.meetingStore.createMeeting(title: "Orphan")
        // Don't flush — meeting stays as pendingUpload

        // Simulate the re-enqueue that would happen on app restart:
        // enqueueSave sets pendingUpload and enqueues to transport
        env.engine.enqueueSave(table: "meetings", id: meeting.id)

        // Now flush — should sync successfully
        env.transport.flush()
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(fetched.syncStatus == .synced)
    }
}
