import Foundation
import OSLog

final class EmbeddingEngine {
    static let shared = EmbeddingEngine()
    private let log = Logger.make("AI")
    private init() {}

    func embed(meetingId: String) async {
        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId),
              let transcript = meeting.rawTranscript, !transcript.isEmpty else { return }

        let provider = await MainActor.run { LLMProviderStore.shared.currentProvider }
        let modelName = await MainActor.run { LLMProviderStore.shared.ollamaModel }
        let chunks = chunkText(transcript)

        for chunk in chunks {
            guard !chunk.isEmpty else { continue }
            do {
                let vector = try await provider.embed(text: chunk)
                let embedding = MeetingEmbedding(
                    id: UUID().uuidString,
                    meetingId: meetingId,
                    chunkText: chunk,
                    embedding: floatsToData(vector),
                    model: modelName
                )
                try MeetingStore.shared.insertEmbedding(embedding)
            } catch {
                self.log.error("Failed to embed chunk: \(error)")
            }
        }
    }

    // MARK: - Chunking (≈384 words per chunk, 128-word overlap)

    func chunkText(_ text: String, chunkSize: Int = 384, overlap: Int = 128) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var chunks: [String] = []
        var start = 0
        while start < words.count {
            let end = min(start + chunkSize, words.count)
            chunks.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start += chunkSize - overlap
        }
        return chunks
    }

    // MARK: - Float32 ↔ Data

    func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    func dataToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
