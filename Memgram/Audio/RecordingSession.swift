import AVFoundation
import Combine
import AppKit
import OSLog
import UserNotifications

/// Owns and coordinates all audio components for a single recording session.
@MainActor
final class RecordingSession: ObservableObject {

    static let shared = RecordingSession()

    private let log = Logger.make("Audio")

    @Published private(set) var isRecording = false
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    @Published private(set) var silentSysAudioSeconds: Double = 0
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var interruptedMeetings: [Meeting] = []
    private var micCapture: MicrophoneCapture?
    private var sysCapture: SystemAudioCaptureProvider?
    private let mixer = StereoMixer()
    private let transcriptionEngine = TranscriptionEngine()
    private var levelCancellables = Set<AnyCancellable>()
    private var chunkCancellable: AnyCancellable?
    private var segmentCancellable: AnyCancellable?
    private var finalizationCancellable: AnyCancellable?
    private var backendCancellable: AnyCancellable?


    private var currentMeetingId: String?
    private var staleTranscriptTimer: Timer?
    private var lastSegmentDate: Date = .distantPast
    private var staleNotificationSent = false

    private init() {
        #if os(macOS)
        backendCancellable = TranscriptionBackendManager.shared.$selectedBackend
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isRecording else { return }
                self.transcriptionEngine.resetTranscriber()
                self.preloadTranscriptionModel()
            }
        #endif
    }

    // MARK: - Startup Preload

    /// Download and warm up the transcription model in the background at app launch.
    /// Safe to call multiple times — TranscriptionEngine.prepare() is idempotent.
    func preloadTranscriptionModel() {
        let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
        Task {
            do {
                try await transcriptionEngine.prepare(modelName: modelName)
            } catch {
                log.error("Transcription model preload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Recovery

    func loadInterruptedMeetings() {
        interruptedMeetings = (try? MeetingStore.shared.interruptedMeetings()) ?? []
    }

    func recoverMeeting(_ meeting: Meeting) {
        do { try MeetingStore.shared.updateStatus(meeting.id, status: .interrupted) }
        catch { log.error("updateStatus(.interrupted) failed for meeting \(meeting.id): \(error)") }
        interruptedMeetings.removeAll { $0.id == meeting.id }
    }

    func discardMeeting(_ meeting: Meeting) {
        do { try MeetingStore.shared.discardMeeting(meeting.id) }
        catch { log.error("discardMeeting failed for meeting \(meeting.id): \(error)") }
        interruptedMeetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Recording

    func start(calendarContext: CalendarContext? = nil) async throws {
        if isRecording {
            log.warning("Starting new recording while another is active — stopping current recording first")
            await stop()
        }

        let title = calendarContext?.eventTitle ?? "Untitled Meeting"
        let meeting = try MeetingStore.shared.createMeeting(
            title: title,
            calendarEventId: nil,
            calendarContext: calendarContext
        )
        currentMeetingId = meeting.id


        // Notify the list immediately so the new meeting appears while recording
        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)

        transcriptionEngine.reset()
        segments = []

        let mic = MicrophoneCapture()
        let sys = makeSystemAudioCapture()

        // Start model loading in background so recording starts immediately.
        // Chunks arriving before the model is ready are silently skipped.
        let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
        Task {
            do {
                try await self.transcriptionEngine.prepare(modelName: modelName)
            } catch {
                self.log.error("Transcription model load failed for '\(modelName)': \(error)")
            }
        }

        try mic.start()
        do {
            try await sys.start()
        } catch {
            mic.stop()
            if let id = currentMeetingId {
                do { try MeetingStore.shared.updateStatus(id, status: .error) }
                catch { log.error("updateStatus(.error) failed for meeting \(id): \(error)") }
            }
            throw error
        }

        mixer.connect(mic: mic.bufferPublisher, system: sys.bufferPublisher)
        micCapture = mic
        sysCapture = sys

        mixer.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (val: Float) in self?.micLevel = val }
            .store(in: &levelCancellables)
        mixer.$sysLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (val: Float) in
                guard let self else { return }
                self.sysLevel = val
                if val > 0 { self.silentSysAudioSeconds = 0 }
                else       { self.silentSysAudioSeconds += 0.1 }
            }
            .store(in: &levelCancellables)

        chunkCancellable = mixer.chunkPublisher
            .sink { [weak self] chunk in
                self?.transcriptionEngine.transcribe(chunk)
            }

        let meetingId = meeting.id
        segmentCancellable = transcriptionEngine.segmentPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                self?.segments.append(segment)          // UI update stays on main
                self?.lastSegmentDate = Date()
                self?.staleNotificationSent = false
                let id = meetingId
                Task.detached(priority: .utility) { [log = self?.log] in    // DB write off main
                    do { try MeetingStore.shared.appendSegment(segment, toMeeting: id) }
                    catch { log?.error("appendSegment failed for meeting \(id): \(error)") }
                }
            }

        isRecording = true
        lastSegmentDate = Date()
        staleNotificationSent = false
        startStaleTranscriptTimer()
    }

    func stop() async {
        stopStaleTranscriptTimer()
        guard isRecording else { return }

        let meetingId = currentMeetingId

        if let id = meetingId {
            do { try MeetingStore.shared.updateStatus(id, status: .transcribing) }
            catch { log.error("updateStatus(.transcribing) failed for meeting \(id): \(error)") }
        }

        mixer.flushAndDisconnect()
        micCapture?.stop()
        await sysCapture?.stop()
        micCapture = nil
        sysCapture = nil
        chunkCancellable = nil
        levelCancellables.removeAll()
        micLevel = 0
        sysLevel = 0
        silentSysAudioSeconds = 0
        isRecording = false

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("memgram")
        do { try FileManager.default.removeItem(at: tmpDir) }
        catch { log.debug("Temp dir removal skipped: \(error)") }

        guard let id = meetingId else { return }

        let finalize = { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }

                #if os(macOS)
                if #available(macOS 14.0, *) {
                    try? MeetingStore.shared.updateStatus(id, status: .done)
                }
                #endif

                let rawTranscript = self.segments
                    .map(\.text)
                    .joined(separator: "\n")
                self.log.info("Finalising meeting \(id) — \(self.segments.count) segments, \(rawTranscript.count) chars")
                do { try MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript) }
                catch { self.log.error("finalizeMeeting failed for meeting \(id): \(error)") }
                self.currentMeetingId = nil
                self.segmentCancellable = nil
                self.finalizationCancellable = nil

                Task {
                    await SummaryEngine.shared.summarize(meetingId: id)  // title generated inside
                    await EmbeddingEngine.shared.embed(meetingId: id)
                }
            }
        }

        if transcriptionEngine.isIdle {
            self.log.info("Transcription already idle — finalising immediately")
            finalize()
        } else {
            self.log.info("Waiting for transcription queue to drain")
            finalizationCancellable = transcriptionEngine.allChunksDonePublisher
                .first()
                .receive(on: DispatchQueue.main)
                .sink { _ in finalize() }

            // Safety net: if WhisperKit hangs and allChunksDonePublisher never fires,
            // finalize after 120 seconds regardless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, self.finalizationCancellable != nil else { return }
                self.log.warning("Transcription drain timed out — finalising anyway")
                self.finalizationCancellable = nil
                finalize()
            }
        }
    }

    // MARK: - Stale Transcript Notification

    private func startStaleTranscriptTimer() {
        staleTranscriptTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkStaleTranscript()
            }
        }
    }

    private func stopStaleTranscriptTimer() {
        staleTranscriptTimer?.invalidate()
        staleTranscriptTimer = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["stale-transcript"])
    }

    private func checkStaleTranscript() {
        guard isRecording, !segments.isEmpty else { return }
        let silenceSeconds = Date().timeIntervalSince(lastSegmentDate)

        // Auto-stop after 10 minutes of no new transcripts
        if silenceSeconds > 600 {
            log.warning("No new transcripts for 10 minutes — auto-stopping recording")
            let content = UNMutableNotificationContent()
            content.title = "Recording auto-stopped"
            content.body = "No new transcripts for 10 minutes. The meeting has been saved."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "stale-transcript", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
            Task { await stop() }
            return
        }

        // Warn at 2 minutes
        if silenceSeconds > 120 && !staleNotificationSent {
            staleNotificationSent = true
            log.warning("No new transcripts for 2 minutes — sending notification")
            let content = UNMutableNotificationContent()
            content.title = "Recording may be stalled"
            content.body = "No new transcripts for 2 minutes. Consider stopping the recording."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "stale-transcript", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}
