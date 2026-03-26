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
            let duration = endedAt.timeIntervalSince(
                (try? Meeting.fetchOne(db, key: meetingId))?.startedAt ?? endedAt
            )
            try db.execute(
                sql: """
                    UPDATE meetings
                    SET status = 'done', ended_at = ?, duration_seconds = ?, raw_transcript = ?
                    WHERE id = ?
                """,
                arguments: [endedAt.timeIntervalSinceReferenceDate, duration, rawTranscript, meetingId]
            )
        }
    }

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

    func interruptedMeetings() throws -> [Meeting] {
        try db.read { db in
            try Meeting
                .filter(Column("status") == MeetingStatus.recording.rawValue)
                .fetchAll(db)
        }
    }
}
