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

        if let modelURL = WhisperModelManager.shared.currentModelURL {
            try? transcriptionEngine.prepare(modelURL: modelURL)
        }
        transcriptionEngine.reset()
        segments = []

        let mic = MicrophoneCapture()
        let sys = makeSystemAudioCapture()

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
                self?.segments.append(segment)
                try? MeetingStore.shared.appendSegment(segment, toMeeting: meetingId)
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
            try? MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript)
            self.currentMeetingId = nil
            self.segmentCancellable = nil
            self.finalizationCancellable = nil

            // Trigger summary + embedding in background (non-blocking)
            Task {
                await SummaryEngine.shared.summarize(meetingId: id)
                await EmbeddingEngine.shared.embed(meetingId: id)
            }
        }

        if transcriptionEngine.isIdle {
            finalize()
        } else {
            finalizationCancellable = transcriptionEngine.allChunksDonePublisher
                .first()
                .receive(on: DispatchQueue.main)
                .sink { _ in finalize() }
        }
    }
}
