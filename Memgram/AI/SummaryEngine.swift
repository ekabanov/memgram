import Foundation

final class SummaryEngine {
    static let shared = SummaryEngine()
    private init() {}

    private let systemPrompt = """
        You are a precise meeting secretary. Produce factual notes directly from the transcript. \
        Be concise. Do not add commentary, preamble, or reasoning steps. \
        Only include information that is explicitly stated in the transcript.
        """

    func summarize(meetingId: String) async {
        print("[SummaryEngine] Starting summarisation for \(meetingId)")

        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else {
            print("[SummaryEngine] ⚠️ Meeting not found: \(meetingId)")
            return
        }
        guard let transcript = meeting.rawTranscript, !transcript.isEmpty else {
            print("[SummaryEngine] ⚠️ rawTranscript is \(meeting.rawTranscript == nil ? "nil" : "empty") — skipping")
            return
        }

        let provider = await MainActor.run { LLMProviderStore.shared.currentProvider }
        print("[SummaryEngine] Using provider: \(provider.name) | transcript length: \(transcript.count) chars")

        do {
            let summary: String
            if (meeting.durationSeconds ?? 0) > 3600 {
                print("[SummaryEngine] Long meeting (>60min) — chunked summarisation")
                summary = try await summarizeLong(meetingId: meetingId, provider: provider)
            } else {
                summary = try await summarizeShort(transcript: transcript, provider: provider)
            }
            let cleanSummary = stripThinkingTags(summary)
            print("[SummaryEngine] ✓ Summary generated (\(cleanSummary.count) chars) — saving")
            try MeetingStore.shared.saveSummary(meetingId: meetingId, summary: cleanSummary)
            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            print("[SummaryEngine] ✓ Saved and notified")
        } catch {
            print("[SummaryEngine] ✗ Failed to summarise meeting \(meetingId): \(error)")
        }
    }

    // MARK: - Private

    private func stripThinkingTags(_ text: String) -> String {
        // Reasoning models output: <think>chain of thought</think>actual answer
        // Strategy: if </think> exists, return everything after it.
        // If only <think> exists (unclosed), return everything before it.
        if let closeRange = text.range(of: "</think>", options: .caseInsensitive) {
            let afterTag = String(text[closeRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !afterTag.isEmpty { return afterTag }
        }
        if let openRange = text.range(of: "<think>", options: .caseInsensitive) {
            let beforeTag = String(text[..<openRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !beforeTag.isEmpty { return beforeTag }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-strips thinking tags from all existing meetings that have summaries.
    /// Call once on launch to clean up summaries generated before this fix.
    func cleanExistingSummaries() {
        Task {
            let meetings = (try? MeetingStore.shared.fetchAll()) ?? []
            for meeting in meetings {
                guard let summary = meeting.summary,
                      summary.contains("<think>") else { continue }
                let cleaned = stripThinkingTags(summary)
                try? MeetingStore.shared.saveSummary(meetingId: meeting.id, summary: cleaned)
                print("[SummaryEngine] Cleaned <think> tags from meeting \(meeting.id)")
            }
            if !meetings.filter({ $0.summary?.contains("<think>") == true }).isEmpty {
                NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            }
        }
    }

    private func summarizeShort(transcript: String, provider: any LLMProvider) async throws -> String {
        let user = """
        /no_think

        Transcript:

        \(transcript)

        Write structured meeting notes in plain text with these sections:

        SUMMARY
        2-3 sentences on the main topic and outcome.

        KEY DECISIONS
        List each decision made, one per line. Write "None" if there are none.

        ACTION ITEMS
        List as "Owner: Task". Write "None" if there are none.

        Rules: use speaker labels when attributing, no markdown, no filler text.
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
