import AVFoundation
import Combine
import AppKit

/// Owns and coordinates all audio components for a single recording session.
@MainActor
final class RecordingSession: ObservableObject {

    static let shared = RecordingSession()

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

    private var currentMeetingId: String?

    private init() {}

    // MARK: - Recovery

    func loadInterruptedMeetings() {
        interruptedMeetings = (try? MeetingStore.shared.interruptedMeetings()) ?? []
    }

    func recoverMeeting(_ meeting: Meeting) {
        try? MeetingStore.shared.updateStatus(meeting.id, status: .done)
        interruptedMeetings.removeAll { $0.id == meeting.id }
    }

    func discardMeeting(_ meeting: Meeting) {
        try? MeetingStore.shared.discardMeeting(meeting.id)
        interruptedMeetings.removeAll { $0.id == meeting.id }
    }

    // MARK: - Recording

    func start() async throws {
        guard !isRecording else { return }

        let meeting = try MeetingStore.shared.createMeeting(
            title: "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
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
                print("[RecordingSession] ✗ WhisperKit load failed for '\(modelName)': \(error)")
            }
        }

        try mic.start()
        do {
            try await sys.start()
        } catch {
            mic.stop()
            if let id = currentMeetingId {
                try? MeetingStore.shared.updateStatus(id, status: .error)
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
                let id = meetingId
                Task.detached(priority: .utility) {    // DB write off main
                    try? MeetingStore.shared.appendSegment(segment, toMeeting: id)
                }
            }

        isRecording = true
    }

    func stop() async {
        guard isRecording else { return }

        let meetingId = currentMeetingId

        if let id = meetingId {
            try? MeetingStore.shared.updateStatus(id, status: .transcribing)
        }

        mixer.disconnect()
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
        try? FileManager.default.removeItem(at: tmpDir)

        guard let id = meetingId else { return }

        let finalize = { [weak self] in
            guard let self else { return }
            let rawTranscript = self.segments
                .map { "\($0.speaker): \($0.text)" }
                .joined(separator: "\n")
            print("[RecordingSession] Finalising meeting \(id) — \(self.segments.count) segments, transcript \(rawTranscript.count) chars")
            try? MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript)
            self.currentMeetingId = nil
            self.segmentCancellable = nil
            self.finalizationCancellable = nil

            Task {
                await SummaryEngine.shared.summarize(meetingId: id)  // title generated inside
                await EmbeddingEngine.shared.embed(meetingId: id)
            }
        }

        if transcriptionEngine.isIdle {
            print("[RecordingSession] Transcription already idle — finalising immediately")
            finalize()
        } else {
            print("[RecordingSession] Waiting for transcription queue to drain before finalising")
            finalizationCancellable = transcriptionEngine.allChunksDonePublisher
                .first()
                .receive(on: DispatchQueue.main)
                .sink { _ in finalize() }

            // Safety net: if WhisperKit hangs and allChunksDonePublisher never fires,
            // finalize after 120 seconds regardless.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, self.finalizationCancellable != nil else { return }
                print("[RecordingSession] ⚠️ Transcription drain timed out — finalising anyway")
                self.finalizationCancellable = nil
                finalize()
            }
        }
    }
}
