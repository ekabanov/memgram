import Foundation
import GRDB

struct MeetingEmbedding: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "embeddings"

    var id: String
    var meetingId: String
    var chunkText: String
    var embedding: Data
    var model: String

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case chunkText = "chunk_text"
        case embedding
        case model
    }
}
