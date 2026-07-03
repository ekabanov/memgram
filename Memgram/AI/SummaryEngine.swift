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
        You write meeting notes that the participants will rely on weeks later. \
        Your notes capture the substance of the conversation — facts, numbers, \
        plans, decisions, commitments — accurately and completely.

        RULES:
        - Only include what is actually in the transcript. Never invent, \
        embellish, or fill gaps with assumptions.
        - Write the content, not the conversation. State facts and plans \
        directly ("Fundraising round targeted for September/October") — never \
        narrate speech acts ("X explained that they are targeting..."). \
        Attribute a point to a person only where ownership matters: decisions, \
        commitments, disagreements, and strong individual positions.
        - When you do attribute: use a name only when the transcript makes the \
        identity certain. A missing attribution is fine; a wrong one is not.
        - Keep every concrete detail: numbers, dates, amounts, names, metrics, \
        deadlines. Replacing a specific figure with a vague phrase is a failure.
        - Transcripts contain speech-recognition errors. Silently correct words \
        that are obviously garbled given the context; keep uncertain proper \
        nouns exactly as transcribed. Use calendar metadata, when provided, to \
        correct names and terms.
        - Plain, direct language. Short sentences. No corporate filler.
        """

    /// Shared output format — used by both the single-pass path and the
    /// long-meeting merge so their results are structurally identical.
    private static let notesFormat = """
        ## Overview
        2-4 sentences: what this conversation was, who was involved (only if \
        evident from the transcript), and the main outcome or theme.

        ## [Topic name]
        One section per major topic actually discussed, with a short concrete \
        heading (never a generic label like "Discussion"). Under each heading, \
        tight bullets carrying the substance: specifics, numbers, reasoning, \
        alternatives that were considered. Fold minor asides into the nearest \
        real topic; drop small talk entirely.

        ## Decisions
        Each decision actually made in the meeting, one bullet each, with the \
        rationale in one clause. OMIT this section if no decisions were made.

        ## Action items
        - **Owner** — task (deadline if mentioned)
        Owner is a name when certain; otherwise "You" for the recording user's \
        commitments or "Them" for the other side's. OMIT if there are none.

        ## Open questions
        Unresolved items and explicitly deferred topics. OMIT if none.

        Never add sections beyond these. Never pad — a short meeting gets \
        short notes. Do not write "None identified"; omit the section instead.
        """

    /// Prompt note explaining the channel-derived speaker labels. Only included
    /// when the transcript actually carries them.
    private static let speakerLabelNote = """
        Transcript speaker labels: "Me:" is the person who recorded this \
        meeting; "Remote:" is everyone on the other end of the call — possibly \
        several different people. This split is reliable ground truth. Use it \
        to assign ownership correctly (action-item owners, sides of a \
        disagreement): the recording user's commitments are "You", the other \
        side's are "Them" or a name. Use a name only when the transcript itself \
        reveals who is speaking (self-introduction, or being addressed by name \
        right before answering). Never guess identities.

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
        \(contextBlock)Read the entire transcript below, then write Markdown meeting notes \
        in exactly this format:

        \(Self.notesFormat)

        Transcript:

        \(transcript)
        """
        return try await streamAndAccumulate(provider: provider, user: user, onChunk: onChunk)
    }

    /// Runs a streaming request, logging time-to-first-token — the number that
    /// separates "provider is slow to respond" from "generation is slow", which
    /// look identical in the UI ("summarising is stuck").
    private func streamAndAccumulate(provider: any LLMProvider, user: String,
                                     onChunk: ((String) -> Void)? = nil) async throws -> String {
        let start = Date()
        var accumulated = ""
        for try await chunk in provider.stream(system: systemPrompt, user: user) {
            if accumulated.isEmpty {
                let ttft = Date().timeIntervalSince(start)
                log.info("First token after \(String(format: "%.1f", ttft))s from \(provider.name)")
                if ttft > 20 {
                    log.warning("Slow first token (\(String(format: "%.1f", ttft))s) — provider queueing or hidden reasoning phase")
                }
            }
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
        The following are notes from consecutive segments of ONE long meeting:

        \(combined)

        Merge them into a single set of meeting notes in exactly this format:

        \(Self.notesFormat)

        Merging rules: combine duplicate topics into one section; keep every \
        concrete detail (numbers, dates, names, commitments); keep ownership \
        attributions exactly as stated in the segment notes — never merge \
        different people's statements into one attribution, never invent names; \
        a topic resolved in a later segment supersedes the open question from \
        an earlier one.
        """
        return try await streamAndAccumulate(provider: provider, user: user, onChunk: onChunk)
    }

    private func summarizeLong(meetingId: String, calendarContext: CalendarContext?,
                                provider: any LLMProvider,
                                onChunk: ((String) -> Void)? = nil) async throws -> String {
        let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        let windows = chunkByCharCount(segments, maxChars: 70_000)
        log.info("Chunked \(segments.count) segments into \(windows.count) windows")

        var chunkSummaries: [String] = []
        for (index, window) in windows.enumerated() {
            // The window passes don't stream to the UI (their output is
            // intermediate), so surface progress through streamingText instead —
            // otherwise a long meeting looks stuck until the final merge starts.
            streamingText[meetingId] = "_Summarising part \(index + 1) of \(windows.count)…_"
            let windowStart = Date()
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
            log.info("Window \(index + 1)/\(windows.count) summarised in \(String(format: "%.1f", Date().timeIntervalSince(windowStart)))s")
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
