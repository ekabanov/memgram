import AVFoundation
import Combine
import AppKit
import OSLog

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

    #if os(macOS)
    @available(macOS 14.0, *)
    private lazy var speakerDiarizer = SpeakerDiarizer()
    #endif

    private var currentMeetingId: String?

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
                log.error("Transcription model preload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #if os(macOS)
        if #available(macOS 14.0, *) {
            Task {
                do { try await speakerDiarizer.prepare() }
                catch { log.error("Diarizer preload failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        #endif
    }

    // MARK: - Recovery

    func loadInterruptedMeetings() {
        interruptedMeetings = (try? MeetingStore.shared.interruptedMeetings()) ?? []
    }

    func recoverMeeting(_ meeting: Meeting) {
        do { try MeetingStore.shared.updateStatus(meeting.id, status: .interrupted) }
        catch { log.error("updateStatus(.interrupted) failed for meeting \(meeting.id, privacy: .public): \(error)") }
        interruptedMeetings.removeAll { $0.id == meeting.id }
    }

    func discardMeeting(_ meeting: Meeting) {
        do { try MeetingStore.shared.discardMeeting(meeting.id) }
        catch { log.error("discardMeeting failed for meeting \(meeting.id, privacy: .public): \(error)") }
        interruptedMeetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Recording

    func start(calendarContext: CalendarContext? = nil) async throws {
        guard !isRecording else { return }

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
        #if os(macOS)
        if #available(macOS 14.0, *) { speakerDiarizer.reset() }
        #endif

        let mic = MicrophoneCapture()
        let sys = makeSystemAudioCapture()

        // Start model loading in background so recording starts immediately.
        // Chunks arriving before the model is ready are silently skipped.
        let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
        Task {
            do {
                try await self.transcriptionEngine.prepare(modelName: modelName)
            } catch {
                self.log.error("Transcription model load failed for '\(modelName, privacy: .public)': \(error)")
            }
        }

        try mic.start()
        do {
            try await sys.start()
        } catch {
            mic.stop()
            if let id = currentMeetingId {
                do { try MeetingStore.shared.updateStatus(id, status: .error) }
                catch { log.error("updateStatus(.error) failed for meeting \(id, privacy: .public): \(error)") }
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
                #if os(macOS)
                if #available(macOS 14.0, *) { self?.speakerDiarizer.append(chunk) }
                #endif
            }

        let meetingId = meeting.id
        segmentCancellable = transcriptionEngine.segmentPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                self?.segments.append(segment)          // UI update stays on main
                let id = meetingId
                Task.detached(priority: .utility) { [log = self?.log] in    // DB write off main
                    do { try MeetingStore.shared.appendSegment(segment, toMeeting: id) }
                    catch { log?.error("appendSegment failed for meeting \(id, privacy: .public): \(error)") }
                }
            }

        isRecording = true
    }

    func stop() async {
        guard isRecording else { return }

        let meetingId = currentMeetingId

        if let id = meetingId {
            do { try MeetingStore.shared.updateStatus(id, status: .transcribing) }
            catch { log.error("updateStatus(.transcribing) failed for meeting \(id, privacy: .public): \(error)") }
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
                    try? MeetingStore.shared.updateStatus(id, status: .diarizing)
                    NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                    defer { try? MeetingStore.shared.updateStatus(id, status: .done) }
                    let labelMap = await self.speakerDiarizer.runAndResolve(segments: self.segments)
                    if !labelMap.isEmpty {
                        for i in self.segments.indices {
                            if let label = labelMap[self.segments[i].id.uuidString] {
                                self.segments[i].speaker = label
                            }
                        }
                        for segment in self.segments {
                            if let label = labelMap[segment.id.uuidString] {
                                try? MeetingStore.shared.updateSegmentSpeaker(
                                    id: segment.id.uuidString, speaker: label)
                            }
                        }
                        self.log.info("Diarization complete — updated \(labelMap.count) segment labels")
                        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                    }
                }
                #endif

                let rawTranscript = self.segments
                    .map { "\($0.speaker): \($0.text)" }
                    .joined(separator: "\n")
                self.log.info("Finalising meeting \(id, privacy: .public) — \(self.segments.count) segments, \(rawTranscript.count) chars")
                do { try MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript) }
                catch { self.log.error("finalizeMeeting failed for meeting \(id, privacy: .public): \(error)") }
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
}
