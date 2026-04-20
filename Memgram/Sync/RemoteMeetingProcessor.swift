#if os(macOS)
import AppKit
import CloudKit
import Foundation
import OSLog

/// Watches CloudKit for audio chunks uploaded by iPhone, transcribes them,
/// and triggers summarization when a meeting is complete.
@MainActor
final class RemoteMeetingProcessor {
    static let shared = RemoteMeetingProcessor()

    private let log = Logger.make("RemoteProcessor")
    private let transcriptionEngine = TranscriptionEngine()
    private var pollTimer: Timer?
    private var isProcessing = false
    /// Meeting IDs that had audio chunks processed in this session.
    /// Only these meetings are eligible for finalization — prevents
    /// RemoteMeetingProcessor from touching locally-recorded Mac meetings.
    private var processedMeetingIds: Set<String> = []

    private init() {}

    private var modelReady = false

    func start() {
        guard pollTimer == nil else { return }  // prevent double-start
        log.info("RemoteMeetingProcessor started")
        loadModelWithRetry()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollForChunks() }
        }

        // On wake from sleep, immediately poll and recover stuck chunks
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.log.info("Mac woke from sleep — polling for missed chunks")
                await self?.recoverStuckChunks()
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
            processedMeetingIds.insert(meetingId)
            log.info("Chunk \(chunkIndex) processed and deleted")
        } catch {
            log.error("Failed to process chunk \(chunkIndex): \(error)")
        }
    }

    /// Reset chunks stuck in "processing" (claimed before sleep but never finished).
    private func recoverStuckChunks() async {
        do {
            let count = try await AudioChunkService.shared.resetStuckProcessingChunks()
            if count > 0 {
                log.warning("Reset \(count) chunks stuck in 'processing' back to 'pending'")
            }
        } catch {
            log.error("Failed to recover stuck chunks: \(error)")
        }
    }

    private func checkForCompletedMeetings() async {
        let meetings = (try? MeetingStore.shared.fetchAll()) ?? []

        // Recover meetings stuck in .transcribing for > 15 minutes with no pending chunks.
        // This handles the case where the Mac was asleep and missed the processing window.
        let staleTimeout: TimeInterval = 15 * 60
        for meeting in meetings where meeting.status == .transcribing
                                  && Date().timeIntervalSince(meeting.startedAt) > staleTimeout
                                  && !processedMeetingIds.contains(meeting.id) {
            do {
                let pending = try await AudioChunkService.shared.fetchPendingChunks(meetingId: meeting.id)
                guard pending.isEmpty else { continue }
                log.warning("Meeting \(meeting.id) stuck in .transcribing for >15min with no pending chunks — finalizing")
                processedMeetingIds.insert(meeting.id)  // allow finalization below
            } catch {
                log.error("Failed to check stale meeting \(meeting.id): \(error)")
            }
        }

        // Check meetings we processed this session (including just-recovered stale ones)
        for meeting in meetings where meeting.status == .transcribing
                                  && processedMeetingIds.contains(meeting.id) {
            do {
                let pending = try await AudioChunkService.shared.fetchPendingChunks(meetingId: meeting.id)
                guard pending.isEmpty else { continue }

                // Claim finalization — update status to .done atomically so only one Mac summarizes
                try MeetingStore.shared.updateStatus(meeting.id, status: .done)
                // Re-fetch to confirm we won (another Mac may have also written .done)
                guard let current = try? MeetingStore.shared.fetchMeeting(meeting.id),
                      current.rawTranscript == nil else {
                    log.info("Meeting \(meeting.id) — already finalized by another Mac")
                    continue
                }

                log.info("Meeting \(meeting.id) — all chunks processed, finalizing")
                let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meeting.id)) ?? []
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
