import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "com.memgram.app", category: "WatchRecording")

@MainActor
final class WatchAudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Double = 0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private(set) var recordingURL: URL?

    func start() {
        guard !isRecording else { return }
        log.info("Starting Watch recording")

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            log.error("AVAudioSession setup failed: \(error)")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch_recording_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            audioRecorder = recorder
            recordingURL = url
            isRecording = true
            recordingStartTime = Date()
            log.info("Watch recording started → \(url.lastPathComponent)")
        } catch {
            log.error("AVAudioRecorder start failed: \(error)")
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }
    }

    func stop() -> URL? {
        guard isRecording else { return nil }
        log.info("Stopping Watch recording — \(String(format: "%.0f", self.elapsedSeconds))s")
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        let url = recordingURL
        recordingURL = nil
        elapsedSeconds = 0
        return url
    }
}
