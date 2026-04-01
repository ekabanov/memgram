import Foundation
import OSLog

private let log = Logger.make("Enrollment")

/// Persists the user's display name and voice enrollment audio sample.
/// The audio is stored as raw 32-bit float PCM at 16 kHz mono.
final class SpeakerEnrollmentStore {

    static let shared = SpeakerEnrollmentStore()

    private let nameKey = "enrolledSpeakerName"
    private var audioURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memgram")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("enrollment_voice.pcm")
    }

    private init() {}

    // MARK: - Name

    var enrolledName: String? {
        get { UserDefaults.standard.string(forKey: nameKey) }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    // MARK: - Audio

    func saveAudio(_ samples: [Float]) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: audioURL, options: .atomic)
            log.info("Saved \(samples.count) enrollment samples")
        } catch {
            log.error("Failed to save enrollment audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadAudio() -> [Float]? {
        guard let data = try? Data(contentsOf: audioURL), !data.isEmpty else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
    }

    var hasEnrollment: Bool {
        enrolledName != nil && FileManager.default.fileExists(atPath: audioURL.path)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: nameKey)
        try? FileManager.default.removeItem(at: audioURL)
        log.info("Enrollment cleared")
    }
}
