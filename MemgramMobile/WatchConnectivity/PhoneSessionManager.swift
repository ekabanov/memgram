import WatchConnectivity
import AVFoundation
import Foundation
import OSLog

private let log = Logger.make("WatchConn")

final class PhoneSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = PhoneSessionManager()

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            log.info("WCSession activated on iPhone")
        }
    }

    // MARK: - WCSessionDelegate (required)

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        log.info("WCSession activation: \(activationState.rawValue)")
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        log.info("WCSession became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        log.info("WCSession deactivated — reactivating")
        WCSession.default.activate()
    }

    // MARK: - Calendar context request from Watch

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        if message["requestCalendarContext"] as? Bool == true {
            log.info("Watch requested calendar context")
            Task { @MainActor in
                var reply: [String: Any] = [:]
                if CalendarManager.shared.isEnabled,
                   let event = CalendarManager.shared.findEvent(around: Date()) {
                    reply["eventTitle"] = event.title
                    let ctx = CalendarManager.shared.context(for: event)
                    reply["calendarContextJSON"] = ctx.toJSON()
                    log.info("Sent calendar context to Watch: \(event.title ?? "nil")")
                }
                replyHandler(reply)
            }
        }
    }

    // MARK: - Receive recording file from Watch

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let startedAtInterval = metadata["startedAt"] as? TimeInterval ?? Date().timeIntervalSince1970
        let startedAt = Date(timeIntervalSince1970: startedAtInterval)
        let calendarJSON = metadata["calendarContext"] as? String

        log.info("Received Watch recording: \(file.fileURL.lastPathComponent)")

        // Copy file before WatchConnectivity cleans it up
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch_\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: tempURL)
        } catch {
            log.error("Failed to copy Watch recording: \(error)")
            return
        }

        Task { @MainActor in
            await self.processWatchRecording(fileURL: tempURL, startedAt: startedAt, calendarJSON: calendarJSON)
        }
    }

    // MARK: - Process Watch recording

    @MainActor
    private func processWatchRecording(fileURL: URL, startedAt: Date, calendarJSON: String?) async {
        log.info("Processing Watch recording: \(fileURL.lastPathComponent)")

        var calendarCtx: CalendarContext? = nil
        if let json = calendarJSON {
            calendarCtx = CalendarContext.fromJSON(json)
        }

        let title = calendarCtx?.eventTitle ?? "Untitled Meeting"
        let meetingId: String
        do {
            meetingId = try AudioChunkUploader.shared.startMeeting(title: title, calendarContext: calendarCtx)
        } catch {
            log.error("Failed to create meeting for Watch recording: \(error)")
            return
        }

        // Convert .m4a to raw Float32 PCM
        guard let samples = await convertToFloat32(fileURL: fileURL) else {
            log.error("Failed to convert Watch recording to PCM")
            return
        }
        try? FileManager.default.removeItem(at: fileURL)

        // Chunk into 30-second segments and upload
        let sampleRate = 16000
        let chunkDuration = 30
        let chunkSampleCount = sampleRate * chunkDuration
        var chunkIndex = 0
        var offset = 0

        while offset < samples.count {
            let end = min(offset + chunkSampleCount, samples.count)
            let chunk = Array(samples[offset..<end])
            let offsetSeconds = Double(chunkIndex * chunkDuration)

            let chunkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("watch_chunk_\(chunkIndex).raw")
            let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            do {
                try data.write(to: chunkURL)
                AudioChunkUploader.shared.uploadChunk(fileURL: chunkURL, chunkIndex: chunkIndex, offsetSeconds: offsetSeconds)
                log.info("Watch chunk \(chunkIndex) queued for upload")
            } catch {
                log.error("Failed to write Watch chunk \(chunkIndex): \(error)")
            }

            offset = end
            chunkIndex += 1
        }

        log.info("Watch recording chunked into \(chunkIndex) pieces — finishing upload")
        await AudioChunkUploader.shared.finishRecording()
    }

    // MARK: - Audio conversion

    private func convertToFloat32(fileURL: URL) async -> [Float]? {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let srcFormat = audioFile.processingFormat
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                                    channels: 1, interleaved: false) else { return nil }
            guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
                log.error("Cannot create audio converter")
                return nil
            }

            let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 4096)!
            var allSamples: [Float] = []

            while true {
                let chunkBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096)!
                var error: NSError?
                let status = converter.convert(to: chunkBuffer, error: &error) { _, status in
                    do {
                        try audioFile.read(into: inputBuffer)
                        status.pointee = inputBuffer.frameLength > 0 ? .haveData : .endOfStream
                        return inputBuffer
                    } catch {
                        status.pointee = .endOfStream
                        return inputBuffer
                    }
                }
                if status == .error || status == .endOfStream { break }
                if chunkBuffer.frameLength == 0 { break }
                guard let channelData = chunkBuffer.floatChannelData else { break }
                allSamples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(chunkBuffer.frameLength)))
            }

            log.info("Converted Watch recording: \(allSamples.count) samples (\(String(format: "%.1f", Double(allSamples.count) / 16000.0))s)")
            return allSamples.isEmpty ? nil : allSamples
        } catch {
            log.error("Audio file conversion failed: \(error)")
            return nil
        }
    }
}
