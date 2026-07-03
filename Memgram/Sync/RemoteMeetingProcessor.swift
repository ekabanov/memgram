#if os(macOS)
import AppKit
import CloudKit
import Foundation
import OSLog

/// Watches CloudKit for audio chunks uploaded by iPhone, transcribes them,
/// and triggers summarization when a meeting is complete.
///
/// Handles multi-Mac scenarios: if Mac A claims chunks then sleeps, Mac B
/// recovers them after a staleness timeout and takes over processing.
@MainActor
final class RemoteMeetingProcessor {
    static let shared = RemoteMeetingProcessor()

    private let log = Logger.make("RemoteProcessor")
    private let transcriptionEngine = TranscriptionEngine()
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isProcessing = false

    private init() {}

    /// Whether OUR engine currently holds a loaded model. The model is loaded
    /// lazily when pending chunks appear and unloaded after an idle period —
    /// keeping a second permanently-resident copy (RecordingSession has its own)
    /// would double model memory on exactly the 8–12 GB Macs we protect.
    private var modelLoaded = false

    /// Consecutive chunk-less polls since the last processed chunk.
    private var idlePolls = 0

    /// Unload the model after this many consecutive chunk-less polls (~5 min).
    private let unloadAfterIdlePolls = 30

    /// Back off after a failed model load so a broken download isn't retried
    /// on every 10s poll.
    private var modelLoadBackoffUntil: Date?

    /// Staleness threshold: chunks "processing" for longer than this are
    /// assumed abandoned by another Mac and reset to "pending".
    private let chunkStaleTimeout: TimeInterval = 2 * 60  // 2 minutes

    /// Meetings in .transcribing whose last activity (start or last transcribed
    /// speech) is older than this are auto-finalized with whatever exists.
    private let meetingStaleTimeout: TimeInterval = 5 * 60  // 5 minutes

    /// Max transcription attempts per chunk (per app session) before the chunk
    /// is marked failed so it stops blocking finalization forever.
    private let maxChunkAttempts = 3

    /// Local attempt counter per chunk recordName. Cleared on success/markFailed.
    private var chunkAttempts: [String: Int] = [:]

    /// Meetings this Mac has seen AudioChunk records for. Only these are
    /// fast-path finalized — anything else in .transcribing might be another
    /// device's live recording that synced mid-drain, and must sit quiet for
    /// the stale timeout before we touch it.
    private var chunkMeetingIds: Set<String> = []

    /// Grace period after a meeting ends before the summary janitor kicks in —
    /// gives the finalizing Mac time to summarize through the normal path.
    private let summaryGracePeriod: TimeInterval = 5 * 60

    /// Only recover summaries for meetings that ended within this window, so a
    /// fresh install doesn't churn through months of history.
    private let summaryRecoveryWindow: TimeInterval = 48 * 60 * 60

    /// Per-session summary attempts per meeting — stops a misconfigured LLM
    /// from being retried on every 10s poll.
    private var summaryAttempts: [String: Int] = [:]
    private let maxSummaryAttempts = 2

    /// Consecutive polls that found zero unfinished chunks, per meeting.
    /// CloudKit query indexes lag writes by seconds, so a single empty reading
    /// can miss tail chunks that were just uploaded — require two in a row
    /// before fast-path finalizing.
    private var emptyChunkPolls: [String: Int] = [:]

    func start() {
        guard pollTimer == nil else { return }  // prevent double-start
        log.info("RemoteMeetingProcessor started")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollForChunks() }
        }

        // On startup, recover anything left over from a previous session.
        // Uses the normal staleness threshold — resetting fresh claims would
        // steal chunks another Mac is actively transcribing (duplicated text).
        Task {
            log.info("Startup recovery — resetting stuck chunks and checking stale meetings")
            await recoverStuckChunks(olderThan: chunkStaleTimeout)
            await pollForChunks()
        }

        // On wake from sleep, immediately recover and poll
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.log.info("Mac woke from sleep — recovering stuck chunks")
                    await self.recoverStuckChunks(olderThan: self.chunkStaleTimeout)
                    await self.pollForChunks()
                }
            }
        }
    }

    /// Lazily load the transcription model. Returns true when the model is
    /// usable. Failures back off for 60s so a broken download isn't hammered
    /// on every 10s poll; pending chunks simply wait for the next attempt.
    private func ensureModelLoaded() async -> Bool {
        if modelLoaded { return true }
        if let backoff = modelLoadBackoffUntil, Date() < backoff { return false }

        let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
        do {
            try await transcriptionEngine.prepare(modelName: modelName)
            modelLoaded = true
            modelLoadBackoffUntil = nil
            log.info("Remote transcription engine loaded on demand")
            return true
        } catch {
            log.error("Remote model load failed — backing off 60s: \(error)")
            modelLoadBackoffUntil = Date().addingTimeInterval(60)
            return false
        }
    }

    /// Free the model after a sustained idle period.
    private func unloadModelIfIdle() {
        guard modelLoaded else { return }
        idlePolls += 1
        if idlePolls >= unloadAfterIdlePolls {
            log.info("No remote chunks for ~\(self.unloadAfterIdlePolls * 10)s — unloading transcription model")
            transcriptionEngine.unload()
            modelLoaded = false
            idlePolls = 0
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    private func pollForChunks() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        // Chunk transcription needs the model, which is loaded lazily when work
        // appears and unloaded after ~5 idle minutes. Finalization and summary
        // recovery run regardless — gating them on the model would leave
        // meetings stuck if the model ever fails to load.
        do {
            // Recover chunks stuck in "processing" by another Mac that went away
            await recoverStuckChunks(olderThan: chunkStaleTimeout)

            let chunks = try await AudioChunkService.shared.fetchAllPendingChunks()
            if chunks.isEmpty {
                unloadModelIfIdle()
            } else if await ensureModelLoaded() {
                idlePolls = 0
                log.info("Found \(chunks.count) pending audio chunks")
                let grouped = Dictionary(grouping: chunks) { $0["meetingId"] as? String ?? "" }
                for (meetingId, meetingChunks) in grouped {
                    guard !meetingId.isEmpty else { continue }
                    let sorted = meetingChunks.sorted { ($0["chunkIndex"] as? Int ?? 0) < ($1["chunkIndex"] as? Int ?? 0) }
                    for chunk in sorted {
                        await processChunk(chunk, meetingId: meetingId)
                    }
                }
            }
        } catch {
            log.error("Poll failed: \(error)")
        }

        // Always check — finalization happens AFTER all chunks are processed
        await checkForCompletedMeetings()
        // Recover summaries lost to a Mac that finalized then slept/crashed
        await checkForMissingSummaries()
    }

    private enum ChunkError: Error {
        case missingAsset
    }

    private func processChunk(_ record: CKRecord, meetingId: String) async {
        let chunkIndex = record["chunkIndex"] as? Int ?? 0
        let offsetSeconds = record["offsetSeconds"] as? Double ?? 0
        let recordName = record.recordID.recordName

        // Atomically claim this chunk — first Mac to update wins. `claimed` carries
        // the fresh change tag needed for follow-up CAS saves (release/markFailed);
        // the original `record` keeps the downloaded CKAsset for audio access.
        guard let claimed = await AudioChunkService.shared.claimChunk(record) else { return }

        // Chunk records are proof this meeting is chunk-based (iPhone/Watch) —
        // remember it so checkForCompletedMeetings may fast-path finalize it.
        chunkMeetingIds.insert(meetingId)

        let attempts = (chunkAttempts[recordName] ?? 0) + 1
        chunkAttempts[recordName] = attempts
        log.info("Processing chunk \(chunkIndex) for meeting \(meetingId) (attempt \(attempts))")

        do {
            guard let audioURL = try AudioChunkService.shared.downloadAudioAsset(from: record) else {
                throw ChunkError.missingAsset
            }
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let data = try Data(contentsOf: audioURL)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let chunkDuration = Double(samples.count) / 16_000

            // Idempotency: if segments already cover this chunk's window (an earlier
            // attempt appended them but the delete failed, or another Mac transcribed
            // it), don't transcribe again — that would duplicate transcript text.
            let existing = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
            let alreadyTranscribed = existing.contains {
                $0.startSeconds >= offsetSeconds - 0.5 && $0.startSeconds < offsetSeconds + chunkDuration
            }
            if alreadyTranscribed {
                log.warning("Chunk \(chunkIndex) window already has segments — skipping transcription")
            } else {
                let segments = try await transcriptionEngine.transcribeRawAudio(
                    samples: samples, meetingId: meetingId, offsetSeconds: offsetSeconds
                )
                // Re-check after the (possibly long, possibly sleep-interrupted)
                // transcription: another Mac may have processed this chunk while
                // we were asleep — appending now would duplicate the text.
                let current = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
                let transcribedMeanwhile = current.contains {
                    $0.startSeconds >= offsetSeconds - 0.5 && $0.startSeconds < offsetSeconds + chunkDuration
                }
                if transcribedMeanwhile {
                    log.warning("Chunk \(chunkIndex) was transcribed by another Mac while we worked — discarding our result")
                } else {
                    for segment in segments {
                        try MeetingStore.shared.appendRemoteSegment(segment)
                    }
                    // Notify UI so Mac transcript view refreshes as segments arrive
                    NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                }
            }
            try await AudioChunkService.shared.markDoneAndDelete(recordID: record.recordID)
            chunkAttempts[recordName] = nil
            log.info("Chunk \(chunkIndex) processed and deleted")
        } catch {
            log.error("Failed to process chunk \(chunkIndex) (attempt \(attempts)/\(self.maxChunkAttempts)): \(error)")
            if attempts >= maxChunkAttempts {
                // Poisoned chunk (corrupt audio, missing asset, …) — stop it from
                // blocking finalization and churning the poll loop forever.
                await AudioChunkService.shared.markFailed(claimed)
                chunkAttempts[recordName] = nil
            } else {
                // Release the claim so the next poll retries without waiting
                // for the staleness reset.
                await AudioChunkService.shared.releaseChunk(claimed)
            }
        }
    }

    private func recoverStuckChunks(olderThan maxAge: TimeInterval) async {
        do {
            let count = try await AudioChunkService.shared.resetStuckProcessingChunks(olderThan: maxAge)
            if count > 0 {
                log.warning("Reset \(count) chunks stuck in 'processing' back to 'pending'")
            }
        } catch {
            log.error("Failed to recover stuck chunks: \(error)")
        }
    }

    private func checkForCompletedMeetings() async {
        let meetings = (try? MeetingStore.shared.fetchAll()) ?? []

        for meeting in meetings where meeting.status == .transcribing {
            // Never touch the meeting this Mac is currently recording/draining —
            // RecordingSession owns its finalization.
            if RecordingSession.shared.currentMeetingId == meeting.id { continue }

            do {
                // Check for ANY unfinished chunks (pending OR processing)
                let unfinished = try await AudioChunkService.shared.fetchUnfinishedChunks(meetingId: meeting.id)
                if !unfinished.isEmpty {
                    // Still has chunks being worked on — skip, but remember that
                    // this meeting is chunk-based for the fast-path below.
                    chunkMeetingIds.insert(meeting.id)
                    emptyChunkPolls[meeting.id] = 0
                    continue
                }

                let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meeting.id)) ?? []
                let hasRemoteSegments = !segments.isEmpty

                // Wall-clock time of the last transcribed speech ≈ meeting start +
                // last segment offset. Using startedAt alone would mis-classify a
                // long recording as stale the moment it stops.
                let lastActivity = meeting.startedAt.addingTimeInterval(segments.map(\.endSeconds).max() ?? 0)
                let isStale = Date().timeIntervalSince(lastActivity) > meetingStaleTimeout

                if !hasRemoteSegments {
                    if isStale {
                        log.warning("Meeting \(meeting.id) stuck in .transcribing for >\(Int(self.meetingStaleTimeout/60))min with no segments — marking interrupted")
                        try MeetingStore.shared.updateStatus(meeting.id, status: .interrupted)
                        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                    }
                    continue
                }

                // Fast-path finalize only meetings we know are chunk-based (we saw
                // chunk records for them). Anything else in .transcribing with
                // segments could be another device's live recording that synced
                // mid-drain — it must sit quiet for the stale timeout first.
                if chunkMeetingIds.contains(meeting.id) {
                    // Guard against CloudKit query-index lag: require two
                    // consecutive polls agreeing there are no unfinished chunks
                    // before finalizing, or a tail chunk uploaded seconds ago
                    // could be silently left out of the transcript.
                    let polls = (emptyChunkPolls[meeting.id] ?? 0) + 1
                    emptyChunkPolls[meeting.id] = polls
                    guard polls >= 2 else { continue }
                } else {
                    guard isStale else { continue }
                }

                // Cross-Mac claim: only one Mac finalizes and summarizes.
                guard await AudioChunkService.shared.claimFinalization(meetingId: meeting.id) else {
                    log.info("Meeting \(meeting.id) — finalization claimed by another Mac")
                    continue
                }

                // Local double-check (covers the pre-claim legacy path)
                try MeetingStore.shared.updateStatus(meeting.id, status: .done)
                guard let current = try? MeetingStore.shared.fetchMeeting(meeting.id),
                      current.rawTranscript == nil else {
                    log.info("Meeting \(meeting.id) — already finalized")
                    continue
                }

                log.info("Meeting \(meeting.id) — all chunks processed, finalizing")
                let rawTranscript = segments
                    .sorted { $0.startSeconds < $1.startSeconds }
                    .map(\.text)
                    .joined(separator: "\n")

                try MeetingStore.shared.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: rawTranscript)
                // Clean up any leftover "failed" chunk records for this meeting
                await AudioChunkService.shared.deleteRemainingChunks(meetingId: meeting.id)
                chunkMeetingIds.remove(meeting.id)
                emptyChunkPolls[meeting.id] = nil
                await SummaryEngine.shared.summarize(meetingId: meeting.id)
                await EmbeddingEngine.shared.embed(meetingId: meeting.id)
                log.info("Meeting \(meeting.id) — summarized and done")
            } catch {
                log.error("Failed to finalize meeting \(meeting.id): \(error)")
            }
        }
    }

    /// Macs are unreliable and intermittently available: the Mac that finalized a
    /// meeting may have slept or crashed before (or during) summarization. Pick up
    /// any recent .done meeting with a transcript but no summary and finish the job,
    /// guarded by a cross-Mac claim so only one Mac summarizes.
    private func checkForMissingSummaries() async {
        let meetings = (try? MeetingStore.shared.fetchAll()) ?? []

        for meeting in meetings where meeting.status == .done
            && meeting.syncStatus != .placeholder
            && meeting.summary == nil {

            guard let transcript = meeting.rawTranscript, !transcript.isEmpty else { continue }
            guard let ended = meeting.endedAt else { continue }
            let sinceEnd = Date().timeIntervalSince(ended)
            guard sinceEnd > summaryGracePeriod, sinceEnd < summaryRecoveryWindow else { continue }

            // Skip meetings a local summarization is already running for.
            guard !SummaryEngine.shared.activeMeetingIds.contains(meeting.id) else { continue }

            let attempts = summaryAttempts[meeting.id] ?? 0
            guard attempts < maxSummaryAttempts else { continue }

            // Cross-Mac claim (stale claims from slept Macs are stolen after 15 min).
            guard await AudioChunkService.shared.claimSummarization(meetingId: meeting.id) else { continue }

            summaryAttempts[meeting.id] = attempts + 1
            log.info("Meeting \(meeting.id) — recovering missing summary (attempt \(attempts + 1))")
            await SummaryEngine.shared.summarize(meetingId: meeting.id)
            await EmbeddingEngine.shared.embed(meetingId: meeting.id)
        }
    }
}
#endif
