import Foundation
import GRDB

struct SearchResult {
    var meetingId: String
    var segmentId: String
    var speaker: String
    var snippet: String
    var timestampSeconds: Double
    var score: Float
}

final class SearchEngine {
    static let shared = SearchEngine()
    private init() {}

    func search(query: String, limit: Int = 20) async throws -> [SearchResult] {
        let ftsResults = try ftsSearch(query: query, limit: limit * 2)
        let cosineResults = try await cosineSearch(query: query, limit: limit * 2)
        return merge(fts: ftsResults, cosine: cosineResults, limit: limit)
    }

    // MARK: - FTS5

    private struct FTSResult {
        var meetingId: String
        var segmentId: String
        var speaker: String
        var snippet: String
        var timestampSeconds: Double
        var bm25: Float
    }

    private func ftsSearch(query: String, limit: Int) throws -> [FTSResult] {
        try AppDatabase.shared.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.meeting_id, s.speaker, s.text, s.start_seconds,
                       bm25(segments_fts) AS bm25
                FROM segments_fts
                JOIN segments s ON segments_fts.rowid = s.rowid
                WHERE segments_fts MATCH ?
                ORDER BY bm25
                LIMIT ?
            """, arguments: [query, limit])

            return rows.map {
                FTSResult(
                    meetingId: $0["meeting_id"],
                    segmentId: $0["id"],
                    speaker: $0["speaker"],
                    snippet: $0["text"],
                    timestampSeconds: $0["start_seconds"],
                    bm25: $0["bm25"]
                )
            }
        }
    }

    // MARK: - Cosine

    private struct CosineResult {
        var meetingId: String
        var snippet: String
        var similarity: Float
    }

    private func cosineSearch(query: String, limit: Int) async throws -> [CosineResult] {
        let provider = await MainActor.run { LLMProviderStore.shared.currentProvider }
        let queryVector = try await provider.embed(text: query)
        let allEmbeddings = try MeetingStore.shared.fetchAllEmbeddings()
        let engine = EmbeddingEngine.shared

        return allEmbeddings
            .map { emb -> (MeetingEmbedding, Float) in
                let vec = engine.dataToFloats(emb.embedding)
                return (emb, cosineSimilarity(queryVector, vec))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { CosineResult(meetingId: $0.meetingId, snippet: $0.chunkText, similarity: $1) }
    }

    // MARK: - Merge (BM25 × 0.4 + cosine × 0.6)

    private func merge(fts: [FTSResult], cosine: [CosineResult], limit: Int) -> [SearchResult] {
        // Normalise BM25: negate (bm25 is negative) then divide by max
        let maxBM25 = fts.map { -$0.bm25 }.max() ?? 1
        var combined: [String: SearchResult] = [:]

        for item in fts {
            let normalised: Float = maxBM25 > 0 ? (-item.bm25 / maxBM25) : 0
            combined[item.segmentId] = SearchResult(
                meetingId: item.meetingId,
                segmentId: item.segmentId,
                speaker: item.speaker,
                snippet: item.snippet,
                timestampSeconds: item.timestampSeconds,
                score: normalised * 0.4
            )
        }

        // Add cosine contribution for any FTS result whose meeting matches a cosine result
        for cosineItem in cosine {
            if let matchKey = combined.first(where: { $0.value.meetingId == cosineItem.meetingId })?.key {
                combined[matchKey]?.score += cosineItem.similarity * 0.6
            }
        }

        return combined.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Cosine Similarity

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let len = min(a.count, b.count)
        guard len > 0 else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<len {
            dot  += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }
}
