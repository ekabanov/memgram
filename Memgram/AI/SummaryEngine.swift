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
        You are an expert meeting analyst. You produce accurate, comprehensive, \
        and well-structured meeting summaries. You extract every substantive point \
        discussed — nothing important is lost.

        CRITICAL RULES:
        - ONLY include information explicitly present in the transcript.
        - NEVER fabricate, infer, or assume details not stated.
        - If a section has no relevant content, write "None identified" and move on.
        - Attribute statements, decisions, and tasks to specific speakers when \
        identifiable from the transcript.
        - Preserve the reasoning and context behind decisions, not just the outcomes.
        - Correct obvious transcription errors in proper nouns based on context — do not \
        annotate the corrections. When calendar event metadata is provided, use it to \
        identify speakers and correct proper nouns.
        """

    /// Summarise a meeting. Pass `overrideBackend` to use a specific backend without touching global state.
    func summarize(meetingId: String, overrideBackend: LLMBackend? = nil) async {
        activeMeetingIds.insert(meetingId)
        defer {
            activeMeetingIds.remove(meetingId)
            streamingText.removeValue(forKey: meetingId)
            // Unload Qwen after the last active summary to free ~4–9 GB of memory.
            // Only unload when the queue is empty — concurrent summaries reuse the loaded model.
            #if canImport(MLXLLM)
            if #available(macOS 14, *), activeMeetingIds.isEmpty,
               LLMProviderStore.shared.selectedBackend == .qwen {
                QwenLocalProvider.shared.unload()
            }
            #endif
        }
        lastError = nil
        log.info("Starting summarisation for \(meetingId)")

        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else {
            log.warning("Meeting not found: \(meetingId)")
            return
        }
        // Use rawTranscript if available; fall back to rebuilding from DB segments (older meetings).
        // Strip any legacy speaker prefixes so the LLM receives plain text.
        let transcript: String
        if let raw = meeting.rawTranscript, !raw.isEmpty {
            transcript = Self.stripSpeakerLabels(raw)
        } else {
            let segs = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
            guard !segs.isEmpty else {
                log.warning("No transcript or segments found — skipping")
                return
            }
            transcript = segs.map(\.text).joined(separator: "\n")
            log.warning("rawTranscript missing — rebuilt from \(segs.count) DB segments")
        }

        let calendarCtx = meeting.calendarContext.flatMap { CalendarContext.fromJSON($0) }

        let provider = await MainActor.run {
            overrideBackend.map { LLMProviderStore.shared.providerFor($0) }
                ?? LLMProviderStore.shared.currentProvider
        }
        log.info("Using provider: \(provider.name) | transcript: \(transcript.count) chars")

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

            // Qwen 3.5 has a 32K token context window. With ~3.5 chars/token and
            // ~3K tokens reserved for system prompt, instructions, and output,
            // ~29K tokens (~100K chars) remain for the transcript. Use 80K as a
            // conservative threshold. Cloud providers (Claude/OpenAI/Gemini) have
            // much larger windows so this only triggers for very long transcripts.
            if transcript.count > 80_000 {
                log.info("Long transcript (\(transcript.count) chars) — chunked summarisation")
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
            log.error("Failed to summarise meeting \(meetingId): \(error)")
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

        // Only auto-title if the current title looks like a default (Mac or iPhone)
        let isDefaultTitle = meeting.title == "Untitled Meeting"
        guard isDefaultTitle else {
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
                self.log.info("Cleaned <think> tags from meeting \(meeting.id)")
                cleaned = true
            }
            if cleaned {
                await MainActor.run { NotificationCenter.default.post(name: .meetingDidUpdate, object: nil) }
            }
        }
    }

    /// Remove "SpeakerName: " prefixes from every line so the LLM receives
    /// clean text without any speaker attribution.
    /// Handles legacy transcripts that were saved with "Speaker: text" format.
    private static func stripSpeakerLabels(_ transcript: String) -> String {
        let pattern = try? NSRegularExpression(pattern: #"^[^\n:]+: "#, options: .anchorsMatchLines)
        let range = NSRange(transcript.startIndex..., in: transcript)
        return pattern?.stringByReplacingMatches(in: transcript, range: range, withTemplate: "") ?? transcript
    }

    private func summarizeShort(transcript: String, calendarContext: CalendarContext?,
                                 provider: any LLMProvider,
                                 onChunk: ((String) -> Void)? = nil) async throws -> String {
        var contextBlock = ""
        if let ctx = calendarContext {
            contextBlock = """
            Calendar event metadata:
            \(ctx.promptBlock())

            """
        }
        let user = """
        \(contextBlock)Analyze the meeting transcript below and produce a structured summary in \
        Markdown format. Follow these steps internally before writing:

        1. Identify all distinct topics/agenda items discussed.
        2. For each topic, extract: key points, decisions, rationale, and any \
        disagreements or alternatives considered.
        3. Identify all action items with owners and deadlines.
        4. Identify all open questions and unresolved issues.

        Then produce the summary using EXACTLY this structure:

        ## Key discussion topics
        For each major topic discussed, provide a subsection:
        ### [Topic name]
        Summarize the discussion thoroughly — include specific arguments, data \
        points, examples, and context mentioned. Do not compress away nuance.

        ## Open questions and follow-ups
        List unresolved questions, items explicitly deferred, topics needing \
        further investigation, and any disagreements that were not resolved.

        ## Action items

        FORMATTING RULES:
        - Use concise but complete language — do not sacrifice detail for brevity.
        - If no action items or open questions exist, write \
        "None identified" for that section rather than omitting it.
        - Exclude small talk, greetings, and filler unless they directly affect \
        a decision or action.

        Transcript:

        \(transcript)
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
        let windows = chunkByCharCount(segments, maxChars: 70_000)
        log.info("Chunked \(segments.count) segments into \(windows.count) windows")

        var chunkSummaries: [String] = []
        for window in windows {
            let chunkTranscript = window.map(\.text).joined(separator: "\n")
            let summary = try await summarizeShort(transcript: chunkTranscript, calendarContext: calendarContext, provider: provider)
            chunkSummaries.append(summary)
        }

        return try await summarizeFinal(chunkSummaries: chunkSummaries, provider: provider, onChunk: onChunk)
    }

    /// Split segments into windows that each fit within `maxChars` of formatted
    /// transcript text. Segments are never split — if a single segment exceeds
    /// `maxChars` it gets its own window.
    private func chunkByCharCount(_ segments: [MeetingSegment], maxChars: Int) -> [[MeetingSegment]] {
        guard !segments.isEmpty else { return [] }
        var chunks: [[MeetingSegment]] = []
        var current: [MeetingSegment] = []
        var currentChars = 0
        for seg in segments {
            let segChars = seg.speaker.count + 2 + seg.text.count + 1 // "speaker: text\n"
            if currentChars + segChars > maxChars && !current.isEmpty {
                chunks.append(current)
                current = [seg]
                currentChars = segChars
            } else {
                current.append(seg)
                currentChars += segChars
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
