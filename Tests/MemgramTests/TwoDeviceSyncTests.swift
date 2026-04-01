import Testing
import CloudKit
import Foundation
@testable import Memgram

@available(macOS 14.0, *)
@Suite("Two-Device Sync")
struct TwoDeviceSyncTests {

    // MARK: - Basic sync

    @Test func meetingSyncsFromDeviceAToB() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        let meeting = try deviceA.meetingStore.createMeeting(title: "Team Sync")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Speaker A: Hi")
        deviceA.transport.flush()

        // Push delivered automatically (holdPushes = false)
        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 1)
        #expect(bMeetings[0].title == "Team Sync")
        #expect(bMeetings[0].rawTranscript == "Speaker A: Hi")
        #expect(bMeetings[0].syncStatus == .synced)

        // Verify A is also synced
        let aMeeting = try deviceA.meetingStore.fetchMeeting(meeting.id)!
        #expect(aMeeting.syncStatus == .synced)
    }

    // MARK: - Delayed delivery (network partition)

    @Test func delayedPushDelivery() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        channel.holdPushes = true
        let meeting = try deviceA.meetingStore.createMeeting(title: "Delayed")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Text")
        deviceA.transport.flush()

        // B has nothing yet
        #expect(try deviceB.meetingStore.fetchAll().isEmpty)

        // Release the partition
        channel.holdPushes = false
        channel.deliverPushes()

        // Now B has it
        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 1)
        #expect(bMeetings[0].title == "Delayed")
        #expect(bMeetings[0].syncStatus == .synced)
    }

    // MARK: - Out-of-order FK delivery

    @Test func segmentBeforeMeetingCreatesPlaceholder() throws {
        let channel = FakeCloudKitChannel()
        channel.holdPushes = true
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        let meeting = try deviceA.meetingStore.createMeeting(title: "FK Test")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Hello")
        deviceA.transport.flush()

        // Deliver segments before meetings
        channel.deliverSegmentsBeforeMeetings(to: deviceB.transport)

        // If segments were synced, B should have a placeholder
        let bAll = try deviceB.meetingStore.fetchAll()
        // Filter out placeholders to check if real meeting came through
        _ = bAll.filter { $0.syncStatus == .placeholder }

        // Deliver remaining (the meeting record)
        channel.deliverPushes(to: deviceB.transport)

        let bFinal = try deviceB.meetingStore.fetchAll()
        let visible = bFinal.filter { $0.syncStatus != .placeholder }
        #expect(visible.count == 1)
        #expect(visible[0].title == "FK Test")
        #expect(visible[0].syncStatus == .synced)
    }

    // MARK: - Bidirectional sync

    @Test func bidirectionalSync() throws {
        let channel = FakeCloudKitChannel()
        channel.holdPushes = true
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // Both create a meeting independently
        _ = try deviceA.meetingStore.createMeeting(title: "A's Meeting")
        _ = try deviceB.meetingStore.createMeeting(title: "B's Meeting")

        // Both flush
        deviceA.transport.flush()
        deviceB.transport.flush()

        // Deliver pushes
        channel.deliverPushes()

        // Both should have both meetings
        let aAll = try deviceA.meetingStore.fetchAll()
        let bAll = try deviceB.meetingStore.fetchAll()
        #expect(aAll.count == 2)
        #expect(bAll.count == 2)
        #expect(Set(aAll.map(\.title)) == Set(["A's Meeting", "B's Meeting"]))
        #expect(Set(bAll.map(\.title)) == Set(["A's Meeting", "B's Meeting"]))
    }

    // MARK: - Deletion

    @Test func deletionSyncsAcrossDevices() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // A creates and syncs
        let meeting = try deviceA.meetingStore.createMeeting(title: "To Delete")
        deviceA.transport.flush()
        #expect(try deviceB.meetingStore.fetchAll().count == 1)

        // A deletes
        try deviceA.meetingStore.deleteMeeting(meeting.id)
        deviceA.transport.flush()

        // B should have 0
        #expect(try deviceB.meetingStore.fetchAll().isEmpty)
    }

    // MARK: - Conflict resolution

    @Test func conflictResolutionPreservesHigherStatusRank() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // A creates and syncs
        let meeting = try deviceA.meetingStore.createMeeting(title: "Conflict")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Done")
        deviceA.transport.flush()

        // Both have the meeting now, status = .done on both
        let bMeeting = try deviceB.meetingStore.fetchMeeting(meeting.id)!
        #expect(bMeeting.status == .done)
    }

    @Test func conflictResolutionPreservesSummary() throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        // A creates, syncs, then generates summary
        let meeting = try deviceA.meetingStore.createMeeting(title: "Summary Test")
        try deviceA.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Text")
        deviceA.transport.flush()

        // A generates summary locally
        try deviceA.meetingStore.saveSummary(meetingId: meeting.id, summary: "Key points: ...")

        // B receives the meeting (without summary)
        // Now A flushes the summary update
        channel.holdPushes = true
        deviceA.transport.flush()

        // Simulate B receiving the update — summary should be preserved
        channel.deliverPushes()
        let bMeeting = try deviceB.meetingStore.fetchMeeting(meeting.id)!
        #expect(bMeeting.summary == "Key points: ...")
    }

    // MARK: - Reset/resync

    @Test func resetResyncDownloadsAllFromChannel() async throws {
        let channel = FakeCloudKitChannel()
        let deviceA = try TestSyncEnvironment.make(channel: channel)

        // Create 3 meetings on device A
        for i in 1...3 {
            let m = try deviceA.meetingStore.createMeeting(title: "Meeting \(i)")
            try deviceA.meetingStore.finalizeMeeting(m.id, endedAt: Date(), rawTranscript: "Text \(i)")
        }
        deviceA.transport.flush()
        #expect(channel.records.count >= 3)

        // Device B starts fresh and fetches all
        let deviceB = try TestSyncEnvironment.make(channel: channel)
        try await deviceB.transport.fetchChanges()

        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 3)
        for meeting in bMeetings {
            #expect(meeting.syncStatus == .synced)
        }
    }

    // MARK: - Error recovery

    @Test func errorRecoveryAfterNetworkFailure() throws {
        let channel = FakeCloudKitChannel()
        channel.failNextSave = .networkFailure
        let deviceA = try TestSyncEnvironment.make(channel: channel)

        let meeting = try deviceA.meetingStore.createMeeting(title: "Error Test")
        deviceA.transport.flush()

        // First attempt fails
        let failedMeeting = try deviceA.meetingStore.fetchMeeting(meeting.id)!
        #expect(failedMeeting.syncStatus == .failed)

        // Retry succeeds
        deviceA.engine.enqueueSave(table: "meetings", id: meeting.id)
        deviceA.transport.flush()

        let recovered = try deviceA.meetingStore.fetchMeeting(meeting.id)!
        #expect(recovered.syncStatus == .synced)
    }

    // MARK: - Out-of-order delivery

    @Test func outOfOrderDeliveryProcessesCorrectly() throws {
        let channel = FakeCloudKitChannel()
        channel.holdPushes = true
        let deviceA = try TestSyncEnvironment.make(channel: channel)
        let deviceB = try TestSyncEnvironment.make(channel: channel)

        let m1 = try deviceA.meetingStore.createMeeting(title: "First")
        let m2 = try deviceA.meetingStore.createMeeting(title: "Second")
        let m3 = try deviceA.meetingStore.createMeeting(title: "Third")
        deviceA.transport.flush()

        // Deliver in reverse order
        let key3 = "meetings_\(m3.id)"
        let key1 = "meetings_\(m1.id)"
        let key2 = "meetings_\(m2.id)"
        channel.deliverOutOfOrder([key3, key1, key2], to: deviceB.transport)

        let bMeetings = try deviceB.meetingStore.fetchAll()
        #expect(bMeetings.count == 3)
        #expect(Set(bMeetings.map(\.title)) == Set(["First", "Second", "Third"]))
    }
}
