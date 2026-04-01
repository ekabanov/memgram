import Testing
import Foundation
@testable import Memgram

@Suite("Meeting Status Transitions")
struct MeetingStatusTests {

    // MARK: - Status transitions

    @Test func createMeetingDefaultStatus() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        #expect(meeting.status == .recording)
        #expect(meeting.syncStatus == .pendingUpload)
    }

    @Test func statusTransitionRecordingToTranscribing() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.updateStatus(meeting.id, status: .transcribing)
        let updated = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(updated.status == .transcribing)
    }

    @Test func statusTransitionFullPipeline() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")

        try env.meetingStore.updateStatus(meeting.id, status: .transcribing)
        try env.meetingStore.updateStatus(meeting.id, status: .diarizing)
        try env.meetingStore.updateStatus(meeting.id, status: .done)

        let finalMeeting = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(finalMeeting.status == .done)
    }

    @Test func finalizeMeetingSetsTranscript() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Speaker A: Hello")

        let finalized = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(finalized.status == .done)
        #expect(finalized.rawTranscript == "Speaker A: Hello")
    }

    @Test func finalizeMeetingEmptyTranscript() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "")

        let finalized = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(finalized.status == .done)
        #expect(finalized.rawTranscript == "")
    }

    // MARK: - Interrupted detection

    @Test func interruptedMeetingsFindsRecording() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let _ = try env.meetingStore.createMeeting(title: "Stuck Recording")
        // createMeeting sets status = .recording by default
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.count == 1)
        #expect(interrupted[0].status == .recording)
    }

    @Test func interruptedMeetingsFindsTranscribing() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Stuck")
        try env.meetingStore.updateStatus(meeting.id, status: .transcribing)
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.count == 1)
    }

    @Test func interruptedMeetingsFindsDiarizing() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Stuck")
        try env.meetingStore.updateStatus(meeting.id, status: .diarizing)
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.count == 1)
    }

    @Test func interruptedMeetingsExcludesDone() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Completed")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "Done")
        let interrupted = try env.meetingStore.interruptedMeetings()
        #expect(interrupted.isEmpty)
    }

    // MARK: - Summary and title

    @Test func saveSummaryPersists() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Test")
        try env.meetingStore.saveSummary(meetingId: meeting.id, summary: "Key points: ...")
        let updated = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(updated.summary == "Key points: ...")
    }

    @Test func updateTitlePersists() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Original")
        try env.meetingStore.updateTitle(meeting.id, title: "Renamed")
        let updated = try env.meetingStore.fetchMeeting(meeting.id)!
        #expect(updated.title == "Renamed")
    }

    // MARK: - Filter logic

    @Test func filterHidesPlaceholders() throws {
        let env = try TestSyncEnvironment.makeLocal()
        // Insert a placeholder directly
        try env.db.write { db in
            let placeholder = Meeting(
                id: UUID().uuidString, title: "Syncing…", startedAt: Date(),
                endedAt: nil, durationSeconds: nil, status: .done,
                syncStatus: .placeholder,
                summary: nil, actionItems: nil, rawTranscript: nil,
                ckSystemFields: nil
            )
            try placeholder.insert(db)
        }
        let all = try env.meetingStore.fetchAll()
        let visible = all.filter { $0.syncStatus != .placeholder }
        #expect(visible.isEmpty)
    }

    @Test func filterShowsInterruptedMeetings() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Interrupted")
        try env.meetingStore.updateStatus(meeting.id, status: .interrupted)
        let all = try env.meetingStore.fetchAll()
        let visible = all.filter { $0.syncStatus != .placeholder }
        #expect(visible.count == 1)
    }

    @Test func filterShowsEmptyTranscriptMeetings() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "Empty")
        try env.meetingStore.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: "")
        let all = try env.meetingStore.fetchAll()
        let visible = all.filter { $0.syncStatus != .placeholder }
        #expect(visible.count == 1)
    }

    // MARK: - Delete and discard

    @Test func deleteMeetingRemovesFromDB() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "To Delete")
        try env.meetingStore.deleteMeeting(meeting.id)
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)
        #expect(fetched == nil)
    }

    @Test func discardMeetingRemovesFromDB() throws {
        let env = try TestSyncEnvironment.makeLocal()
        let meeting = try env.meetingStore.createMeeting(title: "To Discard")
        try env.meetingStore.discardMeeting(meeting.id)
        let fetched = try env.meetingStore.fetchMeeting(meeting.id)
        #expect(fetched == nil)
    }
}
