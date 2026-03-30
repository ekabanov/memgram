import Foundation
import OSLog

@MainActor
final class SummaryEngine: ObservableObject {
    static let shared = SummaryEngine()
    private init() {}

    private let log = Logger.make("AI")

    /// Meeting IDs currently being summarised. Observed by UI for progress indicators.
    @Published private(set) var activeMeetingIds: Set<String> = []
    /// Partial summary text being streamed, keyed by meetingId.
    /// Non-nil only while generation is in progress for that meeting.
    @Published private(set) var streamingText: [String: String] = [:]
    @Published private(set) var lastError: (meetingId: String, message: String)?

    private let systemPrompt = """
        You are a professional, detail-oriented Meeting Analyst AI designed to review \
        meeting transcripts and provide comprehensive, clear summaries for effective \
        follow-through. Your outputs must be concise, organized, and actionable for busy \
        professionals who require only the essential information to maximize team \
        productivity and accountability. Use speaker names when attributing statements. \
        Correct obvious transcription errors in proper nouns based on context — do not \
        annotate the corrections. When calendar event metadata is provided, use it to \
        identify speakers and correct proper nouns.
        """

    /// Summarise a meeting. Pass `overrideBackend` to use a specific backend without touching global state.
    func summarize(meetingId: String, overrideBackend: LLMBackend? = nil) async {
        activeMeetingIds.insert(meetingId)
        defer {
            activeMeetingIds.remove(meetingId)
            streamingText.removeValue(forKey: meetingId)
        }
        lastError = nil
        log.info("Starting summarisation for \(meetingId, privacy: .public)")

        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else {
            log.warning("Meeting not found: \(meetingId, privacy: .public)")
            return
        }
        // Use rawTranscript if available; fall back to rebuilding from DB segments (older meetings)
        let transcript: String
        if let raw = meeting.rawTranscript, !raw.isEmpty {
            transcript = raw
        } else {
            let segs = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
            guard !segs.isEmpty else {
                log.warning("No transcript or segments found — skipping")
                return
            }
            transcript = segs.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            log.warning("rawTranscript missing — rebuilt from \(segs.count) DB segments")
        }

        let calendarCtx = meeting.calendarContext.flatMap { CalendarContext.fromJSON($0) }

        let provider = await MainActor.run {
            overrideBackend.map { LLMProviderStore.shared.providerFor($0) }
                ?? LLMProviderStore.shared.currentProvider
        }
        log.info("Using provider: \(provider.name, privacy: .public) | transcript: \(transcript.count) chars")

        do {
            let summary: String
            // Closure that updates streamingText after stripping think-tags.
            // Suppressed while a <think> block is still open (reasoning models).
            let onChunk: (String) -> Void = { [weak self] accumulated in
                guard let self else { return }
                let isThinking = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("<think>") && !accumulated.contains("</think>")
                if !isThinking {
                    let visible = self.stripThinkingTags(accumulated)
                    if !visible.isEmpty {
                        Task { @MainActor [weak self] in
                            self?.streamingText[meetingId] = visible
                        }
                    }
                }
            }

            if (meeting.durationSeconds ?? 0) > 3600 {
                log.info("Long meeting (>60min) — chunked summarisation")
                summary = try await summarizeLong(meetingId: meetingId, calendarContext: calendarCtx,
                                                  provider: provider, onChunk: onChunk)
            } else {
                summary = try await summarizeShort(transcript: transcript, calendarContext: calendarCtx,
                                                   provider: provider, onChunk: onChunk)
            }
            let cleanSummary = stripThinkingTags(summary)
            log.info("Summary generated (\(cleanSummary.count) chars) — saving")
            try MeetingStore.shared.saveSummary(meetingId: meetingId, summary: cleanSummary)
            // Clear active indicator NOW — before title generation which can take a long time
            activeMeetingIds.remove(meetingId)
            streamingText.removeValue(forKey: meetingId)
            await MainActor.run {
                NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            }
            log.info("Summary saved and UI notified")
            // Fire title generation in a separate task so summarize() returns immediately
            Task { await self.generateTitle(meetingId: meetingId, overrideBackend: overrideBackend) }
        } catch {
            log.error("Failed to summarise meeting \(meetingId, privacy: .public): \(error)")
            streamingText.removeValue(forKey: meetingId)
            await MainActor.run {
                self.lastError = (meetingId: meetingId, message: error.localizedDescription)
            }
        }
    }

    /// Generate a short title (4-8 words) from the meeting summary.
    /// Only runs if the meeting currently has a generic default title (starts with "Meeting ").
    func generateTitle(meetingId: String, overrideBackend: LLMBackend? = nil) async {
        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else { return }

        // Only auto-title if the current title looks like the default
        guard meeting.title.hasPrefix("Meeting ") else {
            log.debug("Skipping auto-title — meeting has custom title")
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
            log.info("Auto-title generated (\(generated.count) chars)")
        } catch {
            log.error("Auto-title failed: \(error)")
        }
    }

    // MARK: - Private

    nonisolated func stripThinkingTags(_ text: String) -> String {
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
                self.log.info("Cleaned <think> tags from meeting \(meeting.id, privacy: .public)")
                cleaned = true
            }
            if cleaned {
                await MainActor.run { NotificationCenter.default.post(name: .meetingDidUpdate, object: nil) }
            }
        }
    }

    private func summarizeShort(transcript: String, calendarContext: CalendarContext?,
                                 provider: any LLMProvider,
                                 onChunk: ((String) -> Void)? = nil) async throws -> String {
        var contextBlock = ""
        if let ctx = calendarContext {
            contextBlock = """
            Calendar event metadata (use to correct proper nouns and identify speakers):
            \(ctx.promptBlock())

            """
        }
        let user = """
        \(contextBlock)You will be given a full transcript of a meeting, which may include a mix of \
        speakers, topics, and discussion threads. Participants may use informal language, go off-topic, \
        or interleave multiple subjects. Your job is to distill the transcript into a highly organized, \
        digestible report.

        Transcript:

        \(transcript)

        Instructions:
        1. Identify and list the main topics or agenda items discussed.
        2. Summarize the essential discussions and decisions made for each main topic.
        3. Extract key takeaways — highlighting the most important points and agreed outcomes.
        4. Break down all tasks assigned, specifying the responsible individual(s) and any agreed deadlines.
        5. Clearly list follow-up actions required, including any questions left unresolved and suggested next steps.
        6. If applicable, create an "Open Issues" section for topics needing further discussion.

        Constraints:
        - Do not include irrelevant chit-chat, repeated information, or off-topic remarks.
        - Remain neutral; do not editorialize, speculate, or add content not present in the transcript.
        - Every task must specify both the responsible party and deadline, or note if missing.
        - Summaries should be brief but comprehensive — avoid over-explaining.

        Output in Markdown using these sections:

        ## Main Topics Discussed
        ## Essential Discussions and Decisions
        ## Key Takeaways
        ## Tasks Assigned
        (format: **Task** — Assigned To — Deadline or "No deadline specified")
        ## Follow-Up Actions
        ## Open Issues
        (omit if none)
        """
        var accumulated = ""
        for try await chunk in provider.stream(system: systemPrompt, user: user) {
            accumulated += chunk
            onChunk?(accumulated)
        }
        return accumulated
    }

    private func summarizeFinal(chunkSummaries: [String], provider: any LLMProvider,
                                 onChunk: ((String) -> Void)? = nil) async throws -> String {
        let combined = chunkSummaries.enumerated()
            .map { "Segment \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        let user = """
        The following are notes from consecutive segments of a long meeting, each formatted in Markdown:

        \(combined)

        Merge these into comprehensive combined meeting notes in **Markdown format**. \
        Integrate information across segments — do not repeat the same point multiple times. \
        Cover all significant topics and details.

        Use these sections with ## headings: ## Participants, ## Topics Discussed (with ### subheadings \
        per topic), ## Key Decisions, ## Action Items.
        """
        var accumulated = ""
        for try await chunk in provider.stream(system: systemPrompt, user: user) {
            accumulated += chunk
            onChunk?(accumulated)
        }
        return accumulated
    }

    private func summarizeLong(meetingId: String, calendarContext: CalendarContext?,
                                provider: any LLMProvider,
                                onChunk: ((String) -> Void)? = nil) async throws -> String {
        let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        let windows = chunkByTime(segments, windowMinutes: 20)

        var chunkSummaries: [String] = []
        for window in windows {
            let chunkTranscript = window.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            let summary = try await summarizeShort(transcript: chunkTranscript, calendarContext: calendarContext, provider: provider)
            chunkSummaries.append(summary)
        }

        return try await summarizeFinal(chunkSummaries: chunkSummaries, provider: provider, onChunk: onChunk)
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
