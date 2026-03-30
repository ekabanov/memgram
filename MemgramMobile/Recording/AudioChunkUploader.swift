import Foundation
import OSLog

private let log = Logger.make("ChunkUpload")

/// Manages the lifecycle of an iPhone-initiated recording: meeting creation, chunk upload, finalization.
@MainActor
final class AudioChunkUploader: ObservableObject {
    static let shared = AudioChunkUploader()

    @Published private(set) var currentMeetingId: String?
    @Published private(set) var pendingChunks: Int = 0

    private let store = MeetingStore.shared
    private let chunkService = AudioChunkService.shared

    /// Tracks in-flight upload tasks so we can wait for them on finish.
    private var uploadTasks: [Task<Void, Never>] = []

    private init() {}

    // MARK: - Meeting lifecycle

    /// Creates a new meeting in the local database and returns its ID.
    func startMeeting(title: String, calendarContext: CalendarContext? = nil) throws -> String {
        let meeting = try store.createMeeting(
            title: title,
            calendarContext: calendarContext
        )
        currentMeetingId = meeting.id
        pendingChunks = 0
        uploadTasks.removeAll()
        log.info("Started meeting: \(meeting.id, privacy: .public)")
        return meeting.id
    }

    /// Uploads a single audio chunk via CloudKit. Deletes the local file after successful upload.
    func uploadChunk(fileURL: URL, chunkIndex: Int, offsetSeconds: Double) {
        guard let meetingId = currentMeetingId else {
            log.warning("uploadChunk called with no active meeting")
            return
        }

        pendingChunks += 1

        let record = chunkService.makeChunkRecord(
            meetingId: meetingId,
            chunkIndex: chunkIndex,
            offsetSeconds: offsetSeconds,
            audioFileURL: fileURL
        )

        let task = Task { [chunkService] in
            do {
                try await chunkService.upload(record: record)
                log.info("Chunk \(chunkIndex) uploaded for meeting \(meetingId, privacy: .public)")
            } catch {
                log.error("Chunk \(chunkIndex) upload failed: \(error.localizedDescription, privacy: .public)")
            }

            // Clean up local temp file
            try? FileManager.default.removeItem(at: fileURL)

            await MainActor.run { [weak self] in
                self?.pendingChunks -= 1
            }
        }

        uploadTasks.append(task)
    }

    /// Waits for all pending uploads, then marks the meeting as ready for transcription.
    func finishRecording() async {
        guard let meetingId = currentMeetingId else {
            log.warning("finishRecording called with no active meeting")
            return
        }

        log.info("Waiting for \(self.pendingChunks) pending chunks...")

        // Await all in-flight uploads
        for task in uploadTasks {
            await task.value
        }
        uploadTasks.removeAll()

        // Mark meeting as transcribing so the Mac can pick it up
        do {
            try store.updateStatus(meetingId, status: .transcribing)
            log.info("Meeting \(meetingId, privacy: .public) set to transcribing")
        } catch {
            log.error("Failed to update meeting status: \(error.localizedDescription, privacy: .public)")
        }

        currentMeetingId = nil

        // Schedule a resync after a delay to pick up Mac's transcription results.
        // CKSyncEngine's change token can get stuck when iPhone and Mac write
        // to the same zone concurrently — restarting the engine fixes this.
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
            await MainActor.run {
                CloudSyncEngine.shared.forceResync()
                log.info("Post-recording resync triggered")
            }
        }
    }
}
