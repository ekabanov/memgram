import Foundation
import GRDB

struct MeetingSegment: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segments"

    var id: String
    var meetingId: String
    var speaker: String
    var channel: String
    var startSeconds: Double
    var endSeconds: Double
    var text: String

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId    = "meeting_id"
        case speaker
        case channel
        case startSeconds = "start_seconds"
        case endSeconds   = "end_seconds"
        case text
    }
}
