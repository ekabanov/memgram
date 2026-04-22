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
    private var isProcessing = false

    private init() {}

    private var modelReady = false

    /// Staleness threshold: chunks "processing" for longer than this are
    /// assumed abandoned by another Mac and reset to "pending".
    private let chunkStaleTimeout: TimeInterval = 2 * 60  // 2 minutes

    /// Meetings in .transcribing with no unfinished chunks for longer than
    /// this are auto-finalized with whatever transcript exists.
    private let meetingStaleTimeout: TimeInterval = 5 * 60  // 5 minutes

    func start() {
        guard pollTimer == nil else { return }  // prevent double-start
        log.info("RemoteMeetingProcessor started")
        loadModelWithRetry()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollForChunks() }
        }

        // On startup, recover anything left over from a previous session
        Task {
            log.info("Startup recovery — resetting stuck chunks and checking stale meetings")
            await recoverStuckChunks(olderThan: 0)
            await pollForChunks()
        }

        // On wake from sleep, immediately recover and poll
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.log.info("Mac woke from sleep — recovering stuck chunks")
                await self?.recoverStuckChunks(olderThan: 0)
                await self?.pollForChunks()
            }
        }
    }

    /// Load WhisperKit model, retrying every 30 seconds on failure.
    private func loadModelWithRetry() {
        let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
        Task {
            for attempt in 1...10 {
                do {
                    try await transcriptionEngine.prepare(modelName: modelName)
                    modelReady = true
                    log.info("Remote transcription engine ready (attempt \(attempt))")
                    return
                } catch {
                    log.error("Model load attempt \(attempt) failed: \(error)")
                    if attempt < 10 {
                        try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30s between retries
                    }
                }
            }
            log.error("Model load failed after 10 attempts — remote processing disabled")
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollForChunks() async {
        guard !isProcessing, modelReady else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            // Recover chunks stuck in "processing" by another Mac that went away
            await recoverStuckChunks(olderThan: chunkStaleTimeout)

            let chunks = try await AudioChunkService.shared.fetchAllPendingChunks()
            if !chunks.isEmpty {
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
            // Always check — finalization happens AFTER all chunks are processed
            await checkForCompletedMeetings()
        } catch {
            log.error("Poll failed: \(error)")
        }
    }

    private func processChunk(_ record: CKRecord, meetingId: String) async {
        let chunkIndex = record["chunkIndex"] as? Int ?? 0
        let offsetSeconds = record["offsetSeconds"] as? Double ?? 0

        // Atomically claim this chunk — first Mac to update wins
        guard await AudioChunkService.shared.claimChunk(record) else { return }

        log.info("Processing chunk \(chunkIndex) for meeting \(meetingId)")

        do {
            guard let audioURL = try AudioChunkService.shared.downloadAudioAsset(from: record) else { return }
            defer { try? FileManager.default.removeItem(at: audioURL) }

            let data = try Data(contentsOf: audioURL)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

            let segments = try await transcriptionEngine.transcribeRawAudio(
                samples: samples, meetingId: meetingId, offsetSeconds: offsetSeconds
            )
            for segment in segments {
                try? MeetingStore.shared.appendRemoteSegment(segment)
            }
            // Notify UI so Mac transcript view refreshes as segments arrive
            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            try await AudioChunkService.shared.markDoneAndDelete(recordID: record.recordID)
            log.info("Chunk \(chunkIndex) processed and deleted")
        } catch {
            log.error("Failed to process chunk \(chunkIndex): \(error)")
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
            do {
                // Check for ANY unfinished chunks (pending OR processing)
                let unfinished = try await AudioChunkService.shared.fetchUnfinishedChunks(meetingId: meeting.id)
                if !unfinished.isEmpty {
                    // Still has chunks being worked on — skip
                    continue
                }

                // No unfinished chunks. Either all were processed, or the meeting
                // has been stuck with no chunks at all for a while.
                // Guard: for meetings we didn't process any chunks for, require the
                // stale timeout before finalizing (prevents touching Mac-recorded meetings).
                let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meeting.id)) ?? []
                let hasRemoteSegments = !segments.isEmpty
                let isStale = Date().timeIntervalSince(meeting.startedAt) > meetingStaleTimeout

                guard hasRemoteSegments || isStale else { continue }

                if !hasRemoteSegments && isStale {
                    log.warning("Meeting \(meeting.id) stuck in .transcribing for >\(Int(meetingStaleTimeout/60))min with no segments — marking interrupted")
                    try MeetingStore.shared.updateStatus(meeting.id, status: .interrupted)
                    NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                    continue
                }

                // Claim finalization — update status to .done atomically
                try MeetingStore.shared.updateStatus(meeting.id, status: .done)
                // Re-fetch to confirm we won (another Mac may have also written .done)
                guard let current = try? MeetingStore.shared.fetchMeeting(meeting.id),
                      current.rawTranscript == nil else {
                    log.info("Meeting \(meeting.id) — already finalized by another Mac")
                    continue
                }

                log.info("Meeting \(meeting.id) — all chunks processed, finalizing")
                let rawTranscript = segments
                    .sorted { $0.startSeconds < $1.startSeconds }
                    .map(\.text)
                    .joined(separator: "\n")

                try MeetingStore.shared.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: rawTranscript)
                await SummaryEngine.shared.summarize(meetingId: meeting.id)
                await EmbeddingEngine.shared.embed(meetingId: meeting.id)
                log.info("Meeting \(meeting.id) — summarized and done")
            } catch {
                log.error("Failed to finalize meeting \(meeting.id): \(error)")
            }
        }
    }
}
#endif
