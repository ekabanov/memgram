import Foundation

/// Captured calendar event metadata, stored as JSON on the Meeting record.
/// Snapshot at recording time — survives calendar event deletion or modification.
struct CalendarContext: Codable, Equatable {
    let eventTitle: String
    let notes: String?
    let attendees: [String]   // Display names only
    let organizer: String?
    let startDate: Date
    let endDate: Date

    /// Encode to JSON string for storage in the meetings table.
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else {
            print("[CalendarContext] ⚠️ JSON encode failed")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Decode from JSON string stored in the meetings table.
    static func fromJSON(_ json: String) -> CalendarContext? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8) else {
            print("[CalendarContext] ⚠️ JSON decode failed: invalid UTF-8")
            return nil
        }
        guard let result = try? decoder.decode(CalendarContext.self, from: data) else {
            print("[CalendarContext] ⚠️ JSON decode failed: schema mismatch or corrupt data")
            return nil
        }
        return result
    }

    /// Format as context block for inclusion in LLM prompts.
    func promptBlock() -> String {
        var lines: [String] = []
        lines.append("Calendar Event: \(eventTitle)")
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        lines.append("Scheduled: \(dateFormatter.string(from: startDate)) – \(dateFormatter.string(from: endDate))")
        if let notes, !notes.isEmpty {
            lines.append("Event Notes: \(notes)")
        }
        if !attendees.isEmpty {
            lines.append("Scheduled Attendees: \(attendees.joined(separator: ", "))")
        }
        if let organizer {
            lines.append("Organizer: \(organizer)")
        }
        return lines.joined(separator: "\n")
    }
}
