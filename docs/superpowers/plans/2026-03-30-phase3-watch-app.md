# Phase 3: Watch Recording App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Apple Watch app that records meetings to a local `.m4a` file and transfers it to the paired iPhone for chunking, upload, and Mac processing.

**Architecture:** watchOS target records via `AVAudioSession` to a compressed `.m4a` file. On stop, transfers the file to iPhone via `WatchConnectivity.transferFile()` with calendar context metadata. iPhone receives the file, converts to 16kHz mono PCM, chunks into 30-second segments, creates a meeting, and uploads chunks to CloudKit — reusing the existing `AudioChunkUploader` pipeline. Watch requests calendar context from iPhone via `sendMessage()` on appear.

**Tech Stack:** WatchKit (watchOS 10+), AVFoundation (Watch recording), WatchConnectivity (both sides), existing `AudioChunkUploader` + `MobileAudioRecorder` on iPhone.

---

## File Structure

### New watchOS files

| File | Purpose |
|------|---------|
| `MemgramWatch/MemgramWatchApp.swift` | Watch app entry point |
| `MemgramWatch/WatchRecordingView.swift` | Record/Stop button, timer, status label |
| `MemgramWatch/WatchAudioRecorder.swift` | AVAudioSession → .m4a file recording |
| `MemgramWatch/WatchSessionManager.swift` | WatchConnectivity: send messages, transfer files |

### New iPhone file

| File | Purpose |
|------|---------|
| `MemgramMobile/WatchConnectivity/PhoneSessionManager.swift` | Receives Watch files + calendar requests, routes to AudioChunkUploader |

### Modified files

| File | Change |
|------|--------|
| `project.yml` | Add watchOS target, WatchConnectivity source path for iPhone |
| `MemgramMobile/MemgramMobileApp.swift` | Activate PhoneSessionManager on launch |

---

## Task 1: Add watchOS Target to project.yml

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p MemgramWatch
```

- [ ] **Step 2: Create placeholder Watch app entry point**

Create `MemgramWatch/MemgramWatchApp.swift`:

```swift
import SwiftUI

@main
struct MemgramWatchApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Memgram Watch")
        }
    }
}
```

- [ ] **Step 3: Add watchOS target to project.yml**

Add watchOS deployment target to options:
```yaml
  deploymentTarget:
    macOS: "14.0"
    iOS: "17.0"
    watchOS: "10.0"
```

Add the watchOS target after MemgramMobile (same indentation level as other targets):

```yaml
  MemgramWatch:
    type: application
    platform: watchOS
    deploymentTarget: "10.0"
    sources:
      - path: MemgramWatch
    info:
      path: MemgramWatch/Info.plist
      properties:
        CFBundleIdentifier: com.memgram.mobile.watchkitapp
        CFBundleName: Memgram
        CFBundleDisplayName: Memgram
        WKApplication: true
        WKCompanionAppBundleIdentifier: com.memgram.mobile
        NSMicrophoneUsageDescription: "Memgram records meeting audio on your Apple Watch."
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.memgram.mobile.watchkitapp
        SWIFT_VERSION: "5.9"
        WATCHOS_DEPLOYMENT_TARGET: "10.0"
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: "6N57Z7GY37"
        SWIFT_STRICT_CONCURRENCY: minimal
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
    scheme:
      testTargets: []
```

Note: The Watch bundle ID must be a child of the iPhone bundle ID (`com.memgram.mobile.watchkitapp` under `com.memgram.mobile`).

- [ ] **Step 4: Add WatchConnectivity source path to iPhone target**

In the MemgramMobile target's sources, add:
```yaml
      - path: MemgramMobile/WatchConnectivity
```

Also create the directory:
```bash
mkdir -p MemgramMobile/WatchConnectivity
```

- [ ] **Step 5: Regenerate and verify**

Run: `xcodegen generate`
Expected: Project created with 3 targets (Memgram, MemgramMobile, MemgramWatch).

- [ ] **Step 6: Commit**

```bash
git add project.yml MemgramWatch/ MemgramMobile/WatchConnectivity/
git commit -m "feat: add watchOS target to project"
```

---

## Task 2: Watch Audio Recorder

**Files:**
- Create: `MemgramWatch/WatchAudioRecorder.swift`

- [ ] **Step 1: Create WatchAudioRecorder**

Create `MemgramWatch/WatchAudioRecorder.swift`:

```swift
import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "com.memgram.app", category: "WatchRecording")

/// Records audio on Apple Watch to a compressed .m4a file.
@MainActor
final class WatchAudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Double = 0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingStartTime: Date?

    /// URL of the last completed recording.
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

        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            log.warning("AVAudioSession deactivate failed: \(error)")
        }

        let url = recordingURL
        recordingURL = nil
        elapsedSeconds = 0
        return url
    }
}
```

- [ ] **Step 2: Build watchOS target**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme MemgramWatch -configuration Debug -destination "generic/platform=watchOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 3: Commit**

```bash
git add MemgramWatch/WatchAudioRecorder.swift
git commit -m "feat: WatchAudioRecorder — AVAudioSession .m4a recording on Apple Watch"
```

---

## Task 3: Watch Session Manager (WatchConnectivity — Watch side)

**Files:**
- Create: `MemgramWatch/WatchSessionManager.swift`

- [ ] **Step 1: Create WatchSessionManager**

Create `MemgramWatch/WatchSessionManager.swift`:

```swift
import WatchConnectivity
import Foundation
import os

private let log = Logger(subsystem: "com.memgram.app", category: "WatchSession")

/// Watch-side WatchConnectivity manager.
/// Requests calendar context from iPhone and transfers recording files.
final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    @Published var calendarEventTitle: String?
    @Published var transferStatus: TransferStatus = .idle

    enum TransferStatus: String {
        case idle = "Ready"
        case transferring = "Sending to iPhone…"
        case done = "Sent"
        case failed = "Transfer failed"
    }

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            log.info("WCSession activated")
        }
    }

    // MARK: - Request calendar context from iPhone

    func requestCalendarContext() {
        guard WCSession.default.isReachable else {
            log.info("iPhone not reachable — recording without calendar context")
            return
        }
        WCSession.default.sendMessage(["requestCalendarContext": true], replyHandler: { reply in
            if let title = reply["eventTitle"] as? String {
                Task { @MainActor in
                    self.calendarEventTitle = title
                    log.info("Calendar context received: \(title)")
                }
            }
        }, errorHandler: { error in
            log.warning("Calendar context request failed: \(error.localizedDescription)")
        })
    }

    // MARK: - Transfer recording file to iPhone

    func transferRecording(fileURL: URL, startedAt: Date, calendarContextJSON: String?) {
        var metadata: [String: Any] = [
            "startedAt": startedAt.timeIntervalSince1970,
            "source": "watch"
        ]
        if let json = calendarContextJSON {
            metadata["calendarContext"] = json
        }

        transferStatus = .transferring
        WCSession.default.transferFile(fileURL, metadata: metadata)
        log.info("File transfer queued: \(fileURL.lastPathComponent)")
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        log.info("WCSession activation: \(activationState.rawValue), error: \(error?.localizedDescription ?? "none")")
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        Task { @MainActor in
            if let error {
                log.error("File transfer failed: \(error.localizedDescription)")
                self.transferStatus = .failed
            } else {
                log.info("File transfer complete")
                self.transferStatus = .done
                // Delete local file after successful transfer
                try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            }
        }
    }
}
```

- [ ] **Step 2: Build watchOS target**

```bash
xcodebuild -project Memgram.xcodeproj -scheme MemgramWatch -configuration Debug -destination "generic/platform=watchOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 3: Commit**

```bash
git add MemgramWatch/WatchSessionManager.swift
git commit -m "feat: WatchSessionManager — calendar context request + file transfer to iPhone"
```

---

## Task 4: Watch Recording View

**Files:**
- Modify: `MemgramWatch/MemgramWatchApp.swift`
- Create: `MemgramWatch/WatchRecordingView.swift`

- [ ] **Step 1: Create WatchRecordingView**

Create `MemgramWatch/WatchRecordingView.swift`:

```swift
import SwiftUI
import os

private let log = Logger(subsystem: "com.memgram.app", category: "WatchUI")

struct WatchRecordingView: View {
    @StateObject private var recorder = WatchAudioRecorder()
    @ObservedObject private var session = WatchSessionManager.shared

    @State private var recordingStartedAt: Date?

    var body: some View {
        VStack(spacing: 12) {
            // Calendar event (if available)
            if let title = session.calendarEventTitle, !recorder.isRecording {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            // Timer
            if recorder.isRecording {
                Text(formatElapsed(recorder.elapsedSeconds))
                    .font(.system(.title, design: .monospaced))
                    .foregroundStyle(.red)
            }

            // Record / Stop button
            Button {
                if recorder.isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? .red : .blue)
                        .frame(width: 60, height: 60)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white)
                            .frame(width: 20, height: 20)
                    } else {
                        Circle()
                            .fill(.white)
                            .frame(width: 22, height: 22)
                    }
                }
            }
            .buttonStyle(.plain)

            // Status
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            session.requestCalendarContext()
        }
    }

    private var statusText: String {
        if recorder.isRecording {
            return "Recording"
        }
        switch session.transferStatus {
        case .idle: return "Tap to record"
        case .transferring: return "Sending to iPhone…"
        case .done: return "Sent to iPhone"
        case .failed: return "Transfer failed"
        }
    }

    private func startRecording() {
        recorder.start()
        recordingStartedAt = Date()
        session.transferStatus = .idle
        log.info("Watch recording started")
    }

    private func stopRecording() {
        guard let fileURL = recorder.stop() else { return }
        let startedAt = recordingStartedAt ?? Date()

        // Build calendar context JSON if we have a title
        var calendarJSON: String? = nil
        if let title = session.calendarEventTitle {
            let ctx = CalendarContextLite(eventTitle: title, startDate: startedAt)
            calendarJSON = ctx.toJSON()
        }

        session.transferRecording(fileURL: fileURL, startedAt: startedAt, calendarContextJSON: calendarJSON)
        log.info("Watch recording stopped and queued for transfer")
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

/// Lightweight calendar context for Watch — no EventKit dependency.
struct CalendarContextLite: Codable {
    let eventTitle: String
    let startDate: Date

    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

- [ ] **Step 2: Replace MemgramWatchApp placeholder**

Replace `MemgramWatch/MemgramWatchApp.swift`:

```swift
import SwiftUI

@main
struct MemgramWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRecordingView()
        }
    }
}
```

- [ ] **Step 3: Build watchOS target**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme MemgramWatch -configuration Debug -destination "generic/platform=watchOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 4: Commit**

```bash
git add MemgramWatch/
git commit -m "feat: WatchRecordingView — record/stop button, timer, calendar context, file transfer"
```

---

## Task 5: iPhone PhoneSessionManager — Receive Watch Files

**Files:**
- Create: `MemgramMobile/WatchConnectivity/PhoneSessionManager.swift`
- Modify: `MemgramMobile/MemgramMobileApp.swift`

- [ ] **Step 1: Create PhoneSessionManager**

Create `MemgramMobile/WatchConnectivity/PhoneSessionManager.swift`:

```swift
import WatchConnectivity
import AVFoundation
import Foundation
import OSLog

private let log = Logger.make("WatchConn")

/// iPhone-side WatchConnectivity manager.
/// Receives recording files from Watch and routes them through the existing upload pipeline.
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

    // MARK: - Handle calendar context request from Watch

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
                } else {
                    log.info("No calendar event to send to Watch")
                }
                replyHandler(reply)
            }
        }
    }

    // MARK: - Handle recording file from Watch

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
            await processWatchRecording(fileURL: tempURL, startedAt: startedAt, calendarJSON: calendarJSON)
        }
    }

    /// Convert .m4a to 16kHz mono PCM, chunk, create meeting, upload.
    @MainActor
    private func processWatchRecording(fileURL: URL, startedAt: Date, calendarJSON: String?) async {
        log.info("Processing Watch recording: \(fileURL.lastPathComponent)")

        // Parse calendar context if provided
        var calendarCtx: CalendarContext? = nil
        if let json = calendarJSON {
            calendarCtx = CalendarContext.fromJSON(json)
        }

        // Create meeting
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

        // Delete the .m4a now that we have the samples
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

            // Write chunk to temp file
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

    /// Convert .m4a file to 16kHz mono Float32 samples.
    private func convertToFloat32(fileURL: URL) async -> [Float]? {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let srcFormat = audioFile.processingFormat
            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                             channels: 1, interleaved: false)!

            guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
                log.error("Cannot create audio converter")
                return nil
            }

            let frameCount = AVAudioFrameCount(Double(audioFile.length) * 16000.0 / srcFormat.sampleRate)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return nil
            }

            var allSamples: [Float] = []
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: 4096)!

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
                let ptr = UnsafeBufferPointer(start: channelData[0], count: Int(chunkBuffer.frameLength))
                allSamples.append(contentsOf: ptr)
            }

            log.info("Converted Watch recording: \(allSamples.count) samples (\(String(format: "%.1f", Double(allSamples.count) / 16000.0))s)")
            return allSamples.isEmpty ? nil : allSamples
        } catch {
            log.error("Audio file conversion failed: \(error)")
            return nil
        }
    }
}
```

- [ ] **Step 2: Activate PhoneSessionManager on iPhone launch**

In `MemgramMobile/MemgramMobileApp.swift`, add to `init()` after CalendarManager:

```swift
        // Start WatchConnectivity to receive Watch recordings
        _ = PhoneSessionManager.shared
```

- [ ] **Step 3: Build both iOS and watchOS targets**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
xcodebuild -project Memgram.xcodeproj -scheme MemgramWatch -configuration Debug -destination "generic/platform=watchOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 4: Commit**

```bash
git add MemgramMobile/WatchConnectivity/ MemgramMobile/MemgramMobileApp.swift
git commit -m "feat: PhoneSessionManager — receives Watch recordings, converts and uploads via AudioChunkUploader"
```

---

## Task 6: Final Build Verification and Push

- [ ] **Step 1: Build all three targets**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Release -destination "platform=macOS" build 2>&1 | tail -3
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Release -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
xcodebuild -project Memgram.xcodeproj -scheme MemgramWatch -configuration Release -destination "generic/platform=watchOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
```

Expected: All three `** BUILD SUCCEEDED **`

- [ ] **Step 2: Push**

```bash
git push
```
