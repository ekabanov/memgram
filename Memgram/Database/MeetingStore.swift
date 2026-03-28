import Foundation
import GRDB

final class MeetingStore {
    static let shared = MeetingStore()
    private let db = AppDatabase.shared
    private init() {}

    private var sync: CloudSyncEngine? {
        if #available(macOS 14.0, *) { return CloudSyncEngine.shared }
        return nil
    }

    // MARK: - Write

    @discardableResult
    func createMeeting(
        title: String,
        calendarEventId: String? = nil,
        calendarContext: CalendarContext? = nil
    ) throws -> Meeting {
        var meeting = Meeting(
            id: UUID().uuidString,
            title: title,
            startedAt: Date(),
            endedAt: nil,
            durationSeconds: nil,
            status: .recording,
            summary: nil,
            actionItems: nil,
            rawTranscript: nil,
            ckSystemFields: nil,
            calendarEventId: calendarEventId,
            calendarContext: calendarContext?.toJSON()
        )
        try db.write { db in try meeting.insert(db) }
        sync?.enqueueSave(table: "meetings", id: meeting.id)
        return meeting
    }

    func updateCalendarContext(_ id: String, eventId: String?, context: CalendarContext) throws {
        try db.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: id) else { return }
            meeting.calendarEventId = eventId
            meeting.calendarContext = context.toJSON()
            try meeting.update(db)
        }
        sync?.enqueueSave(table: "meetings", id: id)
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
        sync?.enqueueSave(table: "segments", id: dbSegment.id)
    }

    func updateStatus(_ meetingId: String, status: MeetingStatus) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET status = ? WHERE id = ?",
                arguments: [status.rawValue, meetingId]
            )
        }
        sync?.enqueueSave(table: "meetings", id: meetingId)
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
        sync?.enqueueSave(table: "meetings", id: meetingId)
    }

    func saveSummary(meetingId: String, summary: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET summary = ? WHERE id = ?",
                arguments: [summary, meetingId]
            )
        }
        sync?.enqueueSave(table: "meetings", id: meetingId)
    }

    func updateTitle(_ meetingId: String, title: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET title = ? WHERE id = ?",
                arguments: [title, meetingId]
            )
        }
        sync?.enqueueSave(table: "meetings", id: meetingId)
    }

    func renameSpeaker(_ oldName: String, to newName: String, inMeeting meetingId: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE segments SET speaker = ? WHERE meeting_id = ? AND speaker = ?",
                arguments: [newName, meetingId, oldName]
            )
        }
        sync?.enqueueSaveSegments(meetingId: meetingId)
    }

    func renameSpeakerGlobally(_ oldName: String, to newName: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE segments SET speaker = ? WHERE speaker = ?",
                arguments: [newName, oldName]
            )
        }
        if let sync = sync {
            do {
                let segments = try db.read { db in
                    try MeetingSegment.filter(Column("speaker") == newName).fetchAll(db)
                }
                for seg in segments {
                    sync.enqueueSave(table: "segments", id: seg.id)
                }
            } catch {}
        }
    }

    /// Discards a meeting that is currently recording (e.g. on crash recovery).
    /// Use `deleteMeeting` to remove a completed meeting from history.
    func discardMeeting(_ meetingId: String) throws {
        if let sync = sync {
            let segments = try db.read { db in
                try MeetingSegment.filter(Column("meeting_id") == meetingId).fetchAll(db)
            }
            for seg in segments { sync.enqueueDelete(table: "segments", id: seg.id) }
            let speakers = try db.read { db in
                try Speaker.filter(Column("meeting_id") == meetingId).fetchAll(db)
            }
            for sp in speakers { sync.enqueueDelete(table: "speakers", id: sp.id) }
        }
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meetingId])
        }
        sync?.enqueueDelete(table: "meetings", id: meetingId)
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
        if let sync = sync {
            let segments = try db.read { db in
                try MeetingSegment.filter(Column("meeting_id") == id).fetchAll(db)
            }
            for seg in segments { sync.enqueueDelete(table: "segments", id: seg.id) }
            let speakers = try db.read { db in
                try Speaker.filter(Column("meeting_id") == id).fetchAll(db)
            }
            for sp in speakers { sync.enqueueDelete(table: "speakers", id: sp.id) }
        }
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
        sync?.enqueueDelete(table: "meetings", id: id)
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
