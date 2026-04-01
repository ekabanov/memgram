import Foundation
import GRDB

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pendingUpload = "pending_upload"
    case placeholder
    case synced
    case failed
}

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording, transcribing, diarizing, done, interrupted, error
}

struct Meeting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetings"

    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var status: MeetingStatus
    var syncStatus: SyncStatus = .pendingUpload
    var summary: String?
    var actionItems: String?
    var rawTranscript: String?
    var ckSystemFields: Data?
    var calendarEventId: String?
    var calendarContext: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case startedAt       = "started_at"
        case endedAt         = "ended_at"
        case durationSeconds = "duration_seconds"
        case status
        case syncStatus      = "sync_status"
        case summary
        case actionItems     = "action_items"
        case rawTranscript   = "raw_transcript"
        case ckSystemFields  = "ck_system_fields"
        case calendarEventId = "calendar_event_id"
        case calendarContext = "calendar_context"
    }
}
