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
        - Attribute statements, decisions, and tasks to a speaker only when the \
        attribution is certain from the transcript or its speaker labels. When \
        unsure who said something, describe WHAT was said without naming WHO — \
        a missing attribution is fine, a wrong one is not.
        - Preserve the reasoning and context behind decisions, not just the outcomes.
        - Correct obvious transcription errors in proper nouns based on context — do not \
        annotate the corrections. When calendar event metadata is provided, use it to \
        correct proper nouns.
        """

    /// Prompt note explaining the channel-derived speaker labels. Only included
    /// when the transcript actually carries them.
    private static let speakerLabelNote = """
        Speaker labels: lines starting with "Me:" were spoken by the person who \
        recorded this meeting (captured through their microphone). Lines starting \
        with "Remote:" are everything that came through the call audio — this may \
        be SEVERAL different people. The Me/Remote split is reliable; treat it as \
        ground truth. Within "Remote", attribute a statement to a named person \
        only when the transcript itself makes the identity clear (a \
        self-introduction, or someone being addressed by name right before \
        answering); otherwise write "a remote participant". Refer to "Me" as \
        "you" or by name if they introduce themselves. Never guess identities.

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
        let summarizeStart = Date()
        log.info("Starting summarisation for \(meetingId)")

        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId) else {
            log.warning("Meeting not found: \(meetingId)")
            return
        }
        // Prefer a channel-annotated transcript built from segments: the
        // You/Remote channel split (mic vs system audio) is physically grounded
        // and lets the LLM attribute statements without guessing. Falls back to
        // plain rawTranscript for meetings without both channels (e.g. iPhone
        // recordings, where everything is one channel).
        let segs = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        let transcript: String
        let speakerNote: String?
        if let annotated = Self.annotatedTranscript(from: segs) {
            transcript = annotated
            speakerNote = Self.speakerLabelNote
        } else if let raw = meeting.rawTranscript, !raw.isEmpty {
            // Strip any legacy speaker prefixes so the LLM receives plain text.
            transcript = Self.stripSpeakerLabels(raw)
            speakerNote = nil
        } else if !segs.isEmpty {
            transcript = segs.map(\.text).joined(separator: "\n")
            speakerNote = nil
            log.warning("rawTranscript missing — rebuilt from \(segs.count) DB segments")
        } else {
            log.warning("No transcript or segments found — skipping")
            return
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
                                                   speakerNote: speakerNote,
                                                   provider: provider, onChunk: onChunk)
            }
            let cleanSummary = stripThinkingTags(summary)
            let elapsed = Date().timeIntervalSince(summarizeStart)
            log.info("Summary generated for \(meetingId) in \(String(format: "%.1f", elapsed))s via \(provider.name) (\(cleanSummary.count) chars) — saving")
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
            let elapsed = Date().timeIntervalSince(summarizeStart)
            log.error("Failed to summarise meeting \(meetingId) after \(String(format: "%.1f", elapsed))s via \(provider.name): \(error)")
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

    /// Build a channel-annotated transcript: consecutive segments from the same
    /// channel are merged into speaker turns ("Me:" = recording user's mic,
    /// "Remote:" = call audio). Returns nil unless BOTH sides are present —
    /// single-channel recordings (iPhone/Watch) carry no usable split, and a
    /// wall of identical labels would only invite the LLM to over-attribute.
    static func annotatedTranscript(from segments: [MeetingSegment]) -> String? {
        let labels = Set(segments.map(\.speaker))
        guard labels.contains("You"), labels.contains("Remote") else { return nil }

        var turns: [(label: String, texts: [String])] = []
        for seg in segments.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let label = seg.speaker == "You" ? "Me" : "Remote"
            if turns.last?.label == label {
                turns[turns.count - 1].texts.append(text)
            } else {
                turns.append((label, [text]))
            }
        }
        guard !turns.isEmpty else { return nil }
        return turns
            .map { "\($0.label): \($0.texts.joined(separator: " "))" }
            .joined(separator: "\n")
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
                                 speakerNote: String? = nil,
                                 provider: any LLMProvider,
                                 onChunk: ((String) -> Void)? = nil) async throws -> String {
        var contextBlock = ""
        if let ctx = calendarContext {
            contextBlock = """
            Calendar event metadata:
            \(ctx.promptBlock())

            """
        }
        if let speakerNote {
            contextBlock += speakerNote
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
        List each task as a bullet: what needs to be done, who owns it (only if \
        the owner is clear from the transcript), and any deadline mentioned.

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
        Cover all significant topics and details. Keep speaker attributions exactly as \
        stated in the segment notes — never merge statements from different speakers \
        into one attribution, and never invent names.

        Use EXACTLY these sections: ## Key discussion topics (with ### subheadings \
        per topic), ## Open questions and follow-ups, ## Action items.
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
            // Annotate each window with the channel-derived speaker turns when
            // available, so attribution survives into the per-chunk notes.
            let chunkTranscript: String
            let note: String?
            if let annotated = Self.annotatedTranscript(from: window) {
                chunkTranscript = annotated
                note = Self.speakerLabelNote
            } else {
                chunkTranscript = window.map(\.text).joined(separator: "\n")
                note = nil
            }
            let summary = try await summarizeShort(transcript: chunkTranscript, calendarContext: calendarContext,
                                                   speakerNote: note, provider: provider)
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
