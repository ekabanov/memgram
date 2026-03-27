import Foundation

final class SummaryEngine {
    static let shared = SummaryEngine()
    private init() {}

    private let systemPrompt = """
        You are a meeting notes assistant. Create comprehensive, well-structured notes from meeting \
        transcripts. Capture all significant topics and details — do not omit important information, \
        structure it well instead. Use speaker names when attributing statements.

        Follow these additional rules:
        - Silently correct obvious transcription spelling errors (e.g. misheard names, technical terms).
        - Mark genuinely uncertain or potentially misheard claims with [possibly: alternate interpretation].
        - Add brief context in [brackets] for acronyms, company names, or technical terms that benefit \
          from explanation — but only when it adds value.
        - Do not add commentary or reasoning steps beyond what is in the transcript.
        """

    /// Summarise a meeting. Pass `overrideBackend` to use a specific backend without touching global state.
    func summarize(meetingId: String, overrideBackend: LLMBackend? = nil) async {
        print("[SummaryEngine] Starting summarisation for \(meetingId)")

        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else {
            print("[SummaryEngine] ⚠️ Meeting not found: \(meetingId)")
            return
        }
        guard let transcript = meeting.rawTranscript, !transcript.isEmpty else {
            print("[SummaryEngine] ⚠️ rawTranscript is \(meeting.rawTranscript == nil ? "nil" : "empty") — skipping")
            return
        }

        let provider = await MainActor.run {
            overrideBackend.map { LLMProviderStore.shared.providerFor($0) }
                ?? LLMProviderStore.shared.currentProvider
        }
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

        Write comprehensive meeting notes in plain text. Do not omit significant topics or details — \
        a longer meeting deserves longer notes. Cover everything that was discussed.

        Use these sections:

        PARTICIPANTS
        Who was in the meeting and their roles (if mentioned).

        TOPICS DISCUSSED
        For each major topic covered, write a paragraph capturing the key points, information shared, \
        and positions expressed. Be thorough — this is the main section.

        KEY DECISIONS
        List each decision reached. Write "None" if there were none.

        ACTION ITEMS
        List as "Owner: Task". Write "None" if there were none.

        Rules: plain text only, no markdown, no meta-commentary about the transcript.
        """
        return try await provider.complete(system: systemPrompt, user: user)
    }

    private func summarizeFinal(chunkSummaries: [String], provider: any LLMProvider) async throws -> String {
        let combined = chunkSummaries.enumerated()
            .map { "Segment \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        let user = """
        /no_think

        The following are notes from consecutive segments of a long meeting:

        \(combined)

        Merge these into comprehensive combined meeting notes covering all segments. \
        Integrate information across segments — do not repeat the same point multiple times. \
        Cover all significant topics and details.

        Use these sections: PARTICIPANTS, TOPICS DISCUSSED, KEY DECISIONS, ACTION ITEMS.
        Plain text only, no markdown.
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

        return try await summarizeFinal(chunkSummaries: chunkSummaries, provider: provider)
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
