import Foundation
import GRDB

final class MeetingStore {
    static let shared = MeetingStore()
    private let db = AppDatabase.shared
    private init() {}

    // MARK: - Write

    @discardableResult
    func createMeeting(title: String) throws -> Meeting {
        let meeting = Meeting(
            id: UUID().uuidString,
            title: title,
            startedAt: Date(),
            endedAt: nil,
            durationSeconds: nil,
            status: .recording,
            summary: nil,
            actionItems: nil,
            rawTranscript: nil
        )
        try db.write { db in try meeting.insert(db) }
        return meeting
    }

    func appendSegment(_ segment: TranscriptSegment, toMeeting meetingId: String) throws {
        let dbSegment = MeetingSegment(
            id: segment.id.uuidString,
            meetingId: meetingId,
            speaker: segment.speaker,
            channel: segment.channel.rawValue,
            startSeconds: segment.startSeconds,
            endSeconds: segment.endSeconds,
            text: segment.text
        )
        try db.write { db in try dbSegment.insert(db) }
    }

    func updateStatus(_ meetingId: String, status: MeetingStatus) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET status = ? WHERE id = ?",
                arguments: [status.rawValue, meetingId]
            )
        }
    }

    func finalizeMeeting(_ meetingId: String, endedAt: Date, rawTranscript: String) throws {
        try db.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else {
                throw DatabaseError(message: "Meeting \(meetingId) not found for finalization")
            }
            meeting.endedAt = endedAt
            meeting.durationSeconds = endedAt.timeIntervalSince(meeting.startedAt)
            meeting.status = .done
            meeting.rawTranscript = rawTranscript
            try meeting.update(db)
        }
    }

    func saveSummary(meetingId: String, summary: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET summary = ? WHERE id = ?",
                arguments: [summary, meetingId]
            )
        }
    }

    func updateTitle(_ meetingId: String, title: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET title = ? WHERE id = ?",
                arguments: [title, meetingId]
            )
        }
    }

    func renameSpeaker(_ oldName: String, to newName: String, inMeeting meetingId: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE segments SET speaker = ? WHERE meeting_id = ? AND speaker = ?",
                arguments: [newName, meetingId, oldName]
            )
        }
    }

    func renameSpeakerGlobally(_ oldName: String, to newName: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE segments SET speaker = ? WHERE speaker = ?",
                arguments: [newName, oldName]
            )
        }
    }

    /// Discards a meeting that is currently recording (e.g. on crash recovery).
    /// Use `deleteMeeting` to remove a completed meeting from history.
    func discardMeeting(_ meetingId: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meetingId])
        }
    }

    // MARK: - Read

    func fetchAll() throws -> [Meeting] {
        try db.read { db in
            try Meeting
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
    }

    func fetchMeeting(_ id: String) throws -> Meeting? {
        try db.read { db in try Meeting.fetchOne(db, key: id) }
    }

    func fetchSegments(forMeeting meetingId: String) throws -> [MeetingSegment] {
        try db.read { db in
            try MeetingSegment
                .filter(Column("meeting_id") == meetingId)
                .order(Column("start_seconds"))
                .fetchAll(db)
        }
    }

    func deleteMeeting(_ id: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
    }

    func insertEmbedding(_ embedding: MeetingEmbedding) throws {
        try db.write { db in try embedding.insert(db) }
    }

    func fetchEmbeddings(forMeeting meetingId: String) throws -> [MeetingEmbedding] {
        try db.read { db in
            try MeetingEmbedding
                .filter(Column("meeting_id") == meetingId)
                .fetchAll(db)
        }
    }

    func fetchAllEmbeddings() throws -> [MeetingEmbedding] {
        try db.read { db in try MeetingEmbedding.fetchAll(db) }
    }

    func interruptedMeetings() throws -> [Meeting] {
        try db.read { db in
            try Meeting
                .filter(Column("status") == MeetingStatus.recording.rawValue
                     || Column("status") == MeetingStatus.transcribing.rawValue)
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
    }
}
