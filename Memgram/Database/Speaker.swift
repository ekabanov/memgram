import Foundation
import GRDB

struct Speaker: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speakers"

    var id: String
    var meetingId: String
    var label: String
    var customName: String?
    var ckSystemFields: Data?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId  = "meeting_id"
        case label
        case customName      = "custom_name"
        case ckSystemFields  = "ck_system_fields"
    }
}
