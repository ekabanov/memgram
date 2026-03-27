import Foundation

@MainActor
final class SummaryEngine: ObservableObject {
    static let shared = SummaryEngine()
    private init() {}

    /// Meeting IDs currently being summarised. Observed by UI for progress indicators.
    @Published private(set) var activeMeetingIds: Set<String> = []

    private let systemPrompt = """
        You are a meeting notes assistant. Create comprehensive, well-structured notes from meeting \
        transcripts. Capture all significant topics and details — do not omit important information, \
        structure it well instead. Use speaker names when attributing statements.

        Follow these additional rules:
        - **Proper noun correction:** When a company name, person name, or product is phonetically \
          transcribed inconsistently (e.g. "Vault" when surrounding context makes clear the speaker \
          means "Bolt"), use the contextually correct version throughout. On its first corrected \
          occurrence, add a note: *(transcript: "original")*. Do not add the note again.
        - **Consistency pass:** Before writing, scan the full transcript for the same entity referred \
          to by multiple similar-sounding names. Pick the one that fits the context and use it \
          consistently.
        - Mark claims that are genuinely ambiguous even after context analysis with \
          [possibly: alternate interpretation] — but only when truly uncertain.
        - Add brief context in [brackets] for acronyms or technical terms that benefit from \
          explanation — only when it adds real value.
        - Do not add commentary or reasoning steps beyond what is in the transcript.
        - Format output as Markdown. Use bullet points and bold for clarity.
        """

    /// Summarise a meeting. Pass `overrideBackend` to use a specific backend without touching global state.
    func summarize(meetingId: String, overrideBackend: LLMBackend? = nil) async {
        activeMeetingIds.insert(meetingId)
        defer { activeMeetingIds.remove(meetingId) }
        print("[SummaryEngine] Starting summarisation for \(meetingId)")

        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else {
            print("[SummaryEngine] ⚠️ Meeting not found: \(meetingId)")
            return
        }
        // Use rawTranscript if available; fall back to rebuilding from DB segments (older meetings)
        let transcript: String
        if let raw = meeting.rawTranscript, !raw.isEmpty {
            transcript = raw
        } else {
            let segs = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
            guard !segs.isEmpty else {
                print("[SummaryEngine] ⚠️ No transcript or segments found — skipping")
                return
            }
            transcript = segs.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            print("[SummaryEngine] ⚠️ rawTranscript missing — rebuilt from \(segs.count) DB segments")
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
            // Clear the active indicator and notify UI BEFORE title generation so progress clears immediately
            await MainActor.run {
                activeMeetingIds.remove(meetingId)
                NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            }
            print("[SummaryEngine] ✓ Saved and notified")
            // Auto-title runs after UI is unblocked (defer is now a no-op for this meetingId)
            await generateTitle(meetingId: meetingId, overrideBackend: overrideBackend)
        } catch {
            print("[SummaryEngine] ✗ Failed to summarise meeting \(meetingId): \(error)")
        }
    }

    /// Generate a short title (4-8 words) from the meeting summary.
    /// Only runs if the meeting currently has a generic default title (starts with "Meeting ").
    func generateTitle(meetingId: String, overrideBackend: LLMBackend? = nil) async {
        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else { return }

        // Only auto-title if the current title looks like the default
        guard meeting.title.hasPrefix("Meeting ") else {
            print("[SummaryEngine] Skipping auto-title — meeting has custom title")
            return
        }

        // Use full summary for the best title; fall back to first 2min transcript if no summary yet
        let source: String
        if let summary = meeting.summary, !summary.isEmpty {
            source = summary
        } else {
            let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
            let first2min = segments.filter { $0.startSeconds < 120 }
            guard !first2min.isEmpty else { return }
            source = first2min.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        }

        let provider = await MainActor.run {
            overrideBackend.map { LLMProviderStore.shared.providerFor($0) }
                ?? LLMProviderStore.shared.currentProvider
        }

        do {
            let raw = try await provider.complete(
                system: "Generate a short meeting title of 4-8 words. Output only the title, nothing else. No quotes, no punctuation at the end.",
                user: "Meeting notes/transcript:\n\n\(source)\n\nGenerate a concise title:"
            )
            let generated = stripThinkingTags(raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !generated.isEmpty, generated.count < 120 else { return }
            try MeetingStore.shared.updateTitle(meetingId, title: generated)
            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            print("[SummaryEngine] ✓ Auto-title: \"\(generated)\"")
        } catch {
            print("[SummaryEngine] ✗ Auto-title failed: \(error)")
        }
    }

    // MARK: - Private

    private nonisolated func stripThinkingTags(_ text: String) -> String {
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
        // Run DB operations off the main actor to avoid blocking the main thread
        Task.detached(priority: .background) {
            let meetings = (try? MeetingStore.shared.fetchAll()) ?? []
            var cleaned = false
            for meeting in meetings {
                guard let summary = meeting.summary,
                      summary.contains("<think>") else { continue }
                let cleanedSummary = self.stripThinkingTags(summary)
                try? MeetingStore.shared.saveSummary(meetingId: meeting.id, summary: cleanedSummary)
                print("[SummaryEngine] Cleaned <think> tags from meeting \(meeting.id)")
                cleaned = true
            }
            if cleaned {
                await MainActor.run { NotificationCenter.default.post(name: .meetingDidUpdate, object: nil) }
            }
        }
    }

    private func summarizeShort(transcript: String, provider: any LLMProvider) async throws -> String {
        let user = """
        /no_think

        Transcript:

        \(transcript)

        Write comprehensive meeting notes in **Markdown format**. Do not omit significant topics or \
        details — a longer meeting deserves longer notes. Cover everything that was discussed.

        Use these sections with ## headings:

        ## Participants
        Who was in the meeting and their roles (if mentioned).

        ## Topics Discussed
        For each major topic covered, use a ### subheading and write bullet points capturing the key \
        points, information shared, and positions expressed. Be thorough — this is the main section.

        ## Key Decisions
        Bullet list of each decision reached. Write "None" if there were none.

        ## Action Items
        Bullet list as "**Owner:** Task". Write "None" if there were none.

        Rules: use markdown formatting (bold, bullets, headings). No meta-commentary about the transcript.
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
