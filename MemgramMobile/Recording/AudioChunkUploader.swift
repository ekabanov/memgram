import CloudKit
import Foundation
import OSLog

private let log = Logger.make("ChunkUpload")

/// Manages the lifecycle of an iPhone-initiated recording: meeting creation, chunk upload, finalization.
///
/// Two API layers:
/// - Explicit-meeting-id methods (`createMeeting`/`uploadChunk(meetingId:...)`/`finishMeeting`) —
///   used by the Watch ingest path so it never touches the phone-recording state.
/// - `currentMeetingId`-based wrappers (`startMeeting`/`uploadChunk(fileURL:...)`/`finishRecording`) —
///   used by the phone recording UI.
@MainActor
final class AudioChunkUploader: ObservableObject {
    static let shared = AudioChunkUploader()

    @Published private(set) var currentMeetingId: String?
    @Published private(set) var pendingChunks: Int = 0
    @Published private(set) var uploadedMeetingId: String?
    /// Chunks that could not be uploaded after all retries. Local files are kept.
    @Published private(set) var failedChunks: Int = 0

    private let store = MeetingStore.shared
    private let chunkService = AudioChunkService.shared

    /// In-flight upload tasks, tracked per meeting so concurrent flows
    /// (phone recording + incoming Watch recording) don't await each other's work.
    private var uploadTasks: [String: [Task<Void, Never>]] = [:]

    private let maxUploadAttempts = 3
    /// Backoff before attempt 2 and attempt 3 (seconds), unless CloudKit suggests its own delay.
    private let retryBackoffSeconds: [Double] = [2, 8]

    private init() {}

    // MARK: - Explicit-meeting-id API

    /// Creates a new meeting in the local database and returns its ID.
    /// Does NOT touch `currentMeetingId` — safe to call while a phone recording is live.
    func createMeeting(title: String, calendarContext: CalendarContext? = nil) throws -> String {
        let meeting = try store.createMeeting(
            title: title,
            calendarContext: calendarContext
        )
        uploadTasks[meeting.id] = []
        log.info("Created meeting: \(meeting.id)")
        return meeting.id
    }

    /// Uploads a single audio chunk via CloudKit, retrying transient failures.
    /// Deletes the local file only after a successful upload; on final failure the
    /// file is kept and `failedChunks` is incremented.
    func uploadChunk(meetingId: String, fileURL: URL, chunkIndex: Int, offsetSeconds: Double) {
        pendingChunks += 1

        let task = Task { [chunkService, maxUploadAttempts, retryBackoffSeconds] in
            var uploaded = false

            for attempt in 1...maxUploadAttempts {
                do {
                    let record = chunkService.makeChunkRecord(
                        meetingId: meetingId,
                        chunkIndex: chunkIndex,
                        offsetSeconds: offsetSeconds,
                        audioFileURL: fileURL
                    )
                    try await chunkService.upload(record: record)
                    log.info("Chunk \(chunkIndex) uploaded for meeting \(meetingId) (attempt \(attempt))")
                    uploaded = true
                    break
                } catch {
                    guard attempt < maxUploadAttempts, Self.isRetryable(error) else {
                        log.error("Chunk \(chunkIndex) upload failed permanently for meeting \(meetingId) after \(attempt) attempt(s): \(error.localizedDescription)")
                        break
                    }
                    let backoff = (error as? CKError)?.retryAfterSeconds
                        ?? retryBackoffSeconds[min(attempt - 1, retryBackoffSeconds.count - 1)]
                    log.warning("Chunk \(chunkIndex) upload failed (attempt \(attempt)), retrying in \(backoff)s: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }

            if uploaded {
                // Clean up local temp file only once the chunk is safely in CloudKit
                try? FileManager.default.removeItem(at: fileURL)
            }

            await MainActor.run { [weak self] in
                self?.pendingChunks -= 1
                if !uploaded {
                    self?.failedChunks += 1
                }
            }
        }

        uploadTasks[meetingId, default: []].append(task)
    }

    /// Waits for the given meeting's pending uploads, then marks it as ready for transcription.
    func finishMeeting(_ meetingId: String) async {
        let tasks = uploadTasks[meetingId] ?? []
        log.info("Waiting for \(tasks.count) upload task(s) for meeting \(meetingId)...")

        for task in tasks {
            await task.value
        }
        uploadTasks[meetingId] = nil

        if failedChunks > 0 {
            log.warning("\(self.failedChunks) chunk(s) failed to upload for meeting \(meetingId) — the transcript may have gaps")
        }

        // Mark meeting as transcribing so the Mac can pick it up
        do {
            try store.updateStatus(meetingId, status: .transcribing)
            log.info("Meeting \(meetingId) set to transcribing")
        } catch {
            log.error("Failed to update meeting status: \(error.localizedDescription)")
        }

        UserDefaults.standard.set(Date(), forKey: "uploadFinishedAt_\(meetingId)")

        // Schedule a fetch after delay to pick up Mac's transcription results.
        // With push notifications working, this is a safety net — the push
        // should trigger a fetch sooner.
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
            log.info("Post-recording fetch triggered")
            await CloudSyncEngine.shared.fetchNow()
        }
    }

    // MARK: - Phone recording lifecycle (currentMeetingId-based wrappers)

    /// Creates a new meeting and makes it the active phone recording.
    func startMeeting(title: String, calendarContext: CalendarContext? = nil) throws -> String {
        uploadedMeetingId = nil
        failedChunks = 0
        let meetingId = try createMeeting(title: title, calendarContext: calendarContext)
        currentMeetingId = meetingId
        log.info("Started meeting: \(meetingId)")
        return meetingId
    }

    /// Uploads a chunk for the active phone recording.
    func uploadChunk(fileURL: URL, chunkIndex: Int, offsetSeconds: Double) {
        guard let meetingId = currentMeetingId else {
            log.warning("uploadChunk called with no active meeting")
            return
        }
        uploadChunk(meetingId: meetingId, fileURL: fileURL, chunkIndex: chunkIndex, offsetSeconds: offsetSeconds)
    }

    /// Finishes the active phone recording.
    func finishRecording() async {
        guard let meetingId = currentMeetingId else {
            log.warning("finishRecording called with no active meeting")
            return
        }

        await finishMeeting(meetingId)

        uploadedMeetingId = meetingId
        currentMeetingId = nil
    }

    /// Called by UI when Mac has finished processing or tracking is no longer needed.
    func clearUploadedMeeting() {
        if let meetingId = uploadedMeetingId {
            UserDefaults.standard.removeObject(forKey: "uploadFinishedAt_\(meetingId)")
        }
        uploadedMeetingId = nil
    }

    // MARK: - Error classification

    /// Transient CloudKit failures worth retrying with backoff.
    private static func isRetryable(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return true
        default:
            return false
        }
    }
}
