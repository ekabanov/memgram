import Foundation

final class SummaryEngine {
    static let shared = SummaryEngine()
    private init() {}

    private let systemPrompt = "You are a concise meeting assistant. Be factual. Use speaker labels."

    func summarize(meetingId: String) async {
        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId),
              let transcript = meeting.rawTranscript, !transcript.isEmpty else { return }

        let provider = await MainActor.run { LLMProviderStore.shared.currentProvider }

        do {
            let summary: String
            if (meeting.durationSeconds ?? 0) > 3600 {
                summary = try await summarizeLong(meetingId: meetingId, provider: provider)
            } else {
                summary = try await summarizeShort(transcript: transcript, provider: provider)
            }
            try MeetingStore.shared.saveSummary(meetingId: meetingId, summary: summary)
            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
        } catch {
            print("[SummaryEngine] Failed to summarise meeting \(meetingId): \(error)")
        }
    }

    // MARK: - Private

    private func summarizeShort(transcript: String, provider: any LLMProvider) async throws -> String {
        let user = """
        Transcript:

        \(transcript)

        Provide: 1) 3-5 sentence summary 2) Key decisions 3) Action items with owner. Plain text, no markdown.
        """
        return try await provider.complete(system: systemPrompt, user: user)
    }

    private func summarizeLong(meetingId: String, provider: any LLMProvider) async throws -> String {
        let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        let windows = chunkByTime(segments, windowMinutes: 20)

        var chunkSummaries: [String] = []
        for window in windows {
            let chunkTranscript = window.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            let summary = try await summarizeShort(transcript: chunkTranscript, provider: provider)
            chunkSummaries.append(summary)
        }

        let combined = chunkSummaries.enumerated()
            .map { "Segment \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        return try await summarizeShort(transcript: combined, provider: provider)
    }

    private func chunkByTime(_ segments: [MeetingSegment], windowMinutes: Double) -> [[MeetingSegment]] {
        let windowSeconds = windowMinutes * 60
        guard !segments.isEmpty else { return [] }
        var chunks: [[MeetingSegment]] = []
        var current: [MeetingSegment] = []
        var windowStart = segments[0].startSeconds
        for seg in segments {
            if seg.startSeconds >= windowStart + windowSeconds {
                if !current.isEmpty { chunks.append(current) }
                current = [seg]
                windowStart = seg.startSeconds
            } else {
                current.append(seg)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
