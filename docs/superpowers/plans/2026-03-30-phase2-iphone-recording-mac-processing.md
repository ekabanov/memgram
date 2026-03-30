# Phase 2: iPhone Recording + Mac Audio Processing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iPhone records meetings and uploads audio chunks to CloudKit; Mac downloads, transcribes, and summarizes; live transcript appears on iPhone as Mac processes.

**Architecture:** iPhone uses `AVAudioSession` to capture 16kHz mono audio, chunks into 30-second segments, and uploads each as a `CKAsset` via direct CloudKit API (not through CKSyncEngine — audio chunks are transient). Mac polls CloudKit for new chunks, transcribes via WhisperKit, writes segments back (which sync to iPhone via existing CKSyncEngine), then deletes the audio. On meeting completion, Mac runs SummaryEngine.

**Tech Stack:** AVAudioSession (iOS), CloudKit direct API (both), WhisperKit (Mac), CKSyncEngine (existing, for segments/meetings), EventKit (iOS).

---

## File Structure

### New shared files (both targets)

| File | Purpose |
|------|---------|
| `Memgram/Sync/AudioChunkService.swift` | CloudKit operations for audio chunks: upload (iOS), query/download/delete (Mac) |

### New Mac-only files

| File | Purpose |
|------|---------|
| `Memgram/Sync/RemoteMeetingProcessor.swift` | Watches CloudKit for audio chunks, transcribes, finalizes meetings, triggers summary |

### New iOS-only files

| File | Purpose |
|------|---------|
| `MemgramMobile/Recording/MobileAudioRecorder.swift` | AVAudioSession recording at 16kHz mono, 30s chunking |
| `MemgramMobile/Recording/AudioChunkUploader.swift` | Upload queue: chunks → CKAssets, retry, cleanup |
| `MemgramMobile/UI/MobileRecordingView.swift` | Record/Stop UI, timer, live transcript, calendar card |

### Modified files

| File | Change |
|------|--------|
| `project.yml` | Add CalendarManager + CalendarNotificationService to iOS target, add new source paths, calendar entitlement |
| `MemgramMobile/MemgramMobileApp.swift` | Add Recording tab, CalendarManager init |
| `Memgram/Transcription/TranscriptionEngine.swift` | Add `transcribeRawAudio(samples:offsetSeconds:) async throws -> [MeetingSegment]` for remote processing |
| `Memgram/AppDelegate.swift` | Start RemoteMeetingProcessor on launch |

---

## Task 1: Update project.yml — Calendar + Recording Infrastructure

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add CalendarManager and CalendarNotificationService to iOS target sources**

In the `MemgramMobile` target's `sources` array, add:
```yaml
      - path: Memgram/Calendar/CalendarManager.swift
      - path: Memgram/Calendar/CalendarNotificationService.swift
```

After the existing `- path: Memgram/Calendar/CalendarContext.swift` line.

- [ ] **Step 2: Add MemgramMobile/Recording source path**

Add to the MemgramMobile sources:
```yaml
      - path: MemgramMobile/Recording
```

- [ ] **Step 3: Add calendar entitlement and usage description for iOS**

In the `MemgramMobile` target's `entitlements.properties`, add:
```yaml
        com.apple.security.personal-information.calendars: true
```

In the `info.properties`, add:
```yaml
        NSCalendarsFullAccessUsageDescription: "Memgram reads your calendar to match recordings with scheduled meetings."
        NSMicrophoneUsageDescription: "Memgram records meeting audio for transcription."
```

- [ ] **Step 4: Create Recording directory**

```bash
mkdir -p MemgramMobile/Recording
```

- [ ] **Step 5: Regenerate and verify**

```bash
xcodegen generate
```

- [ ] **Step 6: Commit**

```bash
git add project.yml
git commit -m "feat: add calendar + recording sources to iOS target"
```

---

## Task 2: AudioChunkService — CloudKit Operations for Audio Chunks

**Files:**
- Create: `Memgram/Sync/AudioChunkService.swift`

- [ ] **Step 1: Create AudioChunkService**

Create `Memgram/Sync/AudioChunkService.swift`. This is shared between Mac and iOS (both need to interact with audio chunk records):

```swift
import CloudKit
import Foundation
import OSLog

/// Direct CloudKit operations for transient audio chunks.
/// Audio chunks bypass CKSyncEngine — they are uploaded, processed, and deleted.
final class AudioChunkService {
    static let shared = AudioChunkService()

    private let log = Logger.make("AudioChunk")
    private let container = CKContainer(identifier: "iCloud.com.memgram.app")
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "MemgramZone")

    private init() {}

    // MARK: - Record type

    static let recordType = "AudioChunk"

    /// Create a CKRecord for an audio chunk with a CKAsset.
    func makeChunkRecord(meetingId: String, chunkIndex: Int, offsetSeconds: Double, audioFileURL: URL) -> CKRecord {
        let recordID = CKRecord.ID(recordName: "audiochunk_\(meetingId)_\(chunkIndex)", zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["meetingId"] = meetingId as CKRecordValue
        record["chunkIndex"] = chunkIndex as CKRecordValue
        record["offsetSeconds"] = offsetSeconds as CKRecordValue
        record["status"] = "pending" as CKRecordValue
        record["audioData"] = CKAsset(fileURL: audioFileURL)
        return record
    }

    // MARK: - Upload (iOS)

    /// Upload a single audio chunk record. Returns on success, throws on failure.
    func upload(record: CKRecord) async throws {
        log.info("Uploading chunk: \(record.recordID.recordName, privacy: .public)")
        let (_, results) = try await database.modifyRecords(saving: [record], deleting: [])
        for (_, result) in results {
            if case .failure(let error) = result {
                throw error
            }
        }
        log.info("Chunk uploaded: \(record.recordID.recordName, privacy: .public)")
    }

    // MARK: - Query (Mac)

    /// Fetch all pending audio chunks for a given meeting, ordered by chunkIndex.
    func fetchPendingChunks(meetingId: String) async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "meetingId == %@ AND status == %@", meetingId, "pending")
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "chunkIndex", ascending: true)]
        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        return try results.map { try $0.1.get() }
    }

    /// Fetch ALL pending audio chunks across all meetings.
    func fetchAllPendingChunks() async throws -> [CKRecord] {
        let predicate = NSPredicate(format: "status == %@", "pending")
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "chunkIndex", ascending: true)]
        let (results, _) = try await database.records(matching: query, inZoneWith: zoneID)
        return try results.map { try $0.1.get() }
    }

    // MARK: - Update + Delete (Mac)

    /// Mark a chunk as done and delete it (removes CKAsset from iCloud storage).
    func markDoneAndDelete(recordID: CKRecord.ID) async throws {
        log.info("Deleting processed chunk: \(recordID.recordName, privacy: .public)")
        let (_, results) = try await database.modifyRecords(saving: [], deleting: [recordID])
        for (_, result) in results {
            if case .failure(let error) = result {
                throw error
            }
        }
        log.info("Chunk deleted: \(recordID.recordName, privacy: .public)")
    }

    // MARK: - Download asset to temp file

    /// Download the audio asset from a chunk record to a local temp file.
    /// Returns the local file URL containing raw Float32 PCM data.
    func downloadAudioAsset(from record: CKRecord) throws -> URL? {
        guard let asset = record["audioData"] as? CKAsset,
              let assetURL = asset.fileURL else {
            log.warning("No audio asset in chunk: \(record.recordID.recordName, privacy: .public)")
            return nil
        }
        // CKAsset.fileURL is a temp file managed by CloudKit — copy it before it's cleaned up
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiochunk_\(UUID().uuidString).raw")
        try FileManager.default.copyItem(at: assetURL, to: tempURL)
        return tempURL
    }
}
```

- [ ] **Step 2: Add to both targets in project.yml**

The file is at `Memgram/Sync/AudioChunkService.swift`. The Mac target already includes all of `Memgram/Sync/` via `path: Memgram`. For iOS, add to MemgramMobile sources:
```yaml
      - path: Memgram/Sync/AudioChunkService.swift
```

- [ ] **Step 3: Build both targets**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 4: Commit**

```bash
git add Memgram/Sync/AudioChunkService.swift project.yml
git commit -m "feat: add AudioChunkService for CloudKit audio chunk upload/query/delete"
```

---

## Task 3: iPhone MobileAudioRecorder — AVAudioSession Recording + Chunking

**Files:**
- Create: `MemgramMobile/Recording/MobileAudioRecorder.swift`

- [ ] **Step 1: Create MobileAudioRecorder**

Create `MemgramMobile/Recording/MobileAudioRecorder.swift`:

```swift
import AVFoundation
import Foundation
import OSLog

/// Records microphone audio on iPhone at 16kHz mono Float32, chunked into 30-second files.
@MainActor
final class MobileAudioRecorder: ObservableObject {
    static let shared = MobileAudioRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds: Double = 0

    private let log = Logger.make("Recording")
    private var audioEngine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private let sampleRate: Double = 16000
    private let chunkDuration: Double = 30  // seconds
    private var chunkIndex = 0
    private var recordingStartTime: Date?
    private var timer: Timer?

    /// Called for each completed 30-second chunk. Provides the temp file URL and chunk metadata.
    var onChunkReady: ((URL, Int, Double) -> Void)?  // (fileURL, chunkIndex, offsetSeconds)

    private init() {}

    func start() throws {
        guard !isRecording else { return }
        log.info("Starting recording")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install a tap that converts to 16kHz mono
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                          channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / inputFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channelData = convertedBuffer.floatChannelData else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))

            Task { @MainActor in
                self.appendSamples(samples)
            }
        }

        try engine.start()
        audioEngine = engine
        sampleBuffer = []
        chunkIndex = 0
        recordingStartTime = Date()
        isRecording = true

        // Elapsed time timer
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedSeconds = Date().timeIntervalSince(start)
            }
        }

        log.info("Recording started")
    }

    func stop() {
        guard isRecording else { return }
        log.info("Stopping recording")

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        timer?.invalidate()
        timer = nil
        isRecording = false

        // Flush remaining samples as a partial chunk
        if !sampleBuffer.isEmpty {
            flushChunk()
        }

        log.info("Recording stopped — \(self.chunkIndex) chunks produced")
    }

    private func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(contentsOf: samples)

        let chunkSampleCount = Int(sampleRate * chunkDuration)
        while sampleBuffer.count >= chunkSampleCount {
            let chunk = Array(sampleBuffer.prefix(chunkSampleCount))
            sampleBuffer.removeFirst(chunkSampleCount)
            writeAndEmitChunk(samples: chunk)
        }
    }

    private func flushChunk() {
        guard !sampleBuffer.isEmpty else { return }
        writeAndEmitChunk(samples: sampleBuffer)
        sampleBuffer = []
    }

    private func writeAndEmitChunk(samples: [Float]) {
        let offsetSeconds = Double(chunkIndex) * chunkDuration
        let index = chunkIndex
        chunkIndex += 1

        // Write raw Float32 to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memgram_chunk_\(index).raw")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try data.write(to: tempURL)
            log.debug("Chunk \(index) written: \(samples.count) samples → \(tempURL.lastPathComponent)")
            onChunkReady?(tempURL, index, offsetSeconds)
        } catch {
            log.error("Failed to write chunk \(index): \(error)")
        }
    }
}
```

- [ ] **Step 2: Build iOS target**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 3: Commit**

```bash
git add MemgramMobile/Recording/MobileAudioRecorder.swift
git commit -m "feat: iPhone MobileAudioRecorder with 16kHz mono recording and 30s chunking"
```

---

## Task 4: iPhone AudioChunkUploader — Upload Queue with Retry

**Files:**
- Create: `MemgramMobile/Recording/AudioChunkUploader.swift`

- [ ] **Step 1: Create AudioChunkUploader**

Create `MemgramMobile/Recording/AudioChunkUploader.swift`:

```swift
import Foundation
import CloudKit
import OSLog

/// Manages the lifecycle of an iPhone-initiated recording:
/// creates the meeting, uploads audio chunks, signals completion.
@MainActor
final class AudioChunkUploader: ObservableObject {
    static let shared = AudioChunkUploader()

    @Published private(set) var currentMeetingId: String?
    @Published private(set) var pendingChunks: Int = 0

    private let log = Logger.make("Upload")
    private var uploadTasks: [Task<Void, Never>] = []

    private init() {}

    /// Start a new recording session: create a meeting record in the local DB + CloudKit.
    func startMeeting(title: String, calendarContext: CalendarContext? = nil) throws -> String {
        let meeting = try MeetingStore.shared.createMeeting(
            title: title,
            calendarContext: calendarContext
        )
        currentMeetingId = meeting.id
        pendingChunks = 0
        log.info("Meeting created: \(meeting.id, privacy: .public) — \(title, privacy: .public)")
        return meeting.id
    }

    /// Queue an audio chunk for upload to CloudKit.
    func uploadChunk(fileURL: URL, chunkIndex: Int, offsetSeconds: Double) {
        guard let meetingId = currentMeetingId else {
            log.error("uploadChunk called with no active meeting")
            return
        }
        pendingChunks += 1
        let record = AudioChunkService.shared.makeChunkRecord(
            meetingId: meetingId,
            chunkIndex: chunkIndex,
            offsetSeconds: offsetSeconds,
            audioFileURL: fileURL
        )

        let task = Task {
            do {
                try await AudioChunkService.shared.upload(record: record)
                await MainActor.run { self.pendingChunks -= 1 }
                // Delete local file after successful upload
                try? FileManager.default.removeItem(at: fileURL)
                self.log.debug("Chunk \(chunkIndex) uploaded and local file deleted")
            } catch {
                self.log.error("Chunk \(chunkIndex) upload failed: \(error)")
                // Keep pending count — retry logic can be added later
            }
        }
        uploadTasks.append(task)
    }

    /// Signal that recording has stopped. Updates meeting status to .transcribing.
    func finishRecording() async {
        guard let meetingId = currentMeetingId else { return }

        // Wait for all pending uploads to complete
        log.info("Waiting for \(self.pendingChunks) pending chunk uploads…")
        for task in uploadTasks {
            await task.value
        }
        uploadTasks = []

        // Update meeting status to transcribing — Mac picks this up and runs summary
        do {
            try MeetingStore.shared.updateStatus(meetingId, status: .transcribing)
            log.info("Meeting \(meetingId, privacy: .public) status → transcribing")
        } catch {
            log.error("Failed to update meeting status: \(error)")
        }

        currentMeetingId = nil
    }
}
```

- [ ] **Step 2: Build iOS target**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 3: Commit**

```bash
git add MemgramMobile/Recording/AudioChunkUploader.swift
git commit -m "feat: AudioChunkUploader — meeting creation, chunk upload queue, status management"
```

---

## Task 5: Mac TranscriptionEngine Extension — Transcribe Raw Audio

**Files:**
- Modify: `Memgram/Transcription/TranscriptionEngine.swift`

- [ ] **Step 1: Add transcribeRawAudio method**

Read `TranscriptionEngine.swift`. Add a new public method after `prepare()` that transcribes a raw Float32 array and returns `MeetingSegment` records directly (for use by RemoteMeetingProcessor):

```swift
    /// Transcribe a raw Float32 audio array and return segments.
    /// Used by RemoteMeetingProcessor for remote audio chunks.
    func transcribeRawAudio(samples: [Float], meetingId: String, offsetSeconds: Double) async throws -> [MeetingSegment] {
        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            task: .transcribe,
            temperature: 0.0,
            skipSpecialTokens: true
        )
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        var segments: [MeetingSegment] = []
        for result in results {
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let seg = MeetingSegment(
                    id: UUID().uuidString,
                    meetingId: meetingId,
                    speaker: "Remote",  // iPhone recordings are single-channel
                    channel: "microphone",
                    startSeconds: offsetSeconds + segment.start,
                    endSeconds: offsetSeconds + segment.end,
                    text: text,
                    ckSystemFields: nil
                )
                segments.append(seg)
            }
        }
        log.info("Transcribed \(segments.count) segments from \(samples.count) samples at offset \(offsetSeconds)s")
        return segments
    }
```

Also add the error enum if it doesn't exist:
```swift
enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? { "Whisper model is not loaded" }
}
```

- [ ] **Step 2: Build Mac target**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

- [ ] **Step 3: Commit**

```bash
git add Memgram/Transcription/TranscriptionEngine.swift
git commit -m "feat: add transcribeRawAudio() for remote audio chunk processing"
```

---

## Task 6: Mac RemoteMeetingProcessor

**Files:**
- Create: `Memgram/Sync/RemoteMeetingProcessor.swift`

- [ ] **Step 1: Create RemoteMeetingProcessor**

Create `Memgram/Sync/RemoteMeetingProcessor.swift`:

```swift
import CloudKit
import Foundation
import OSLog

/// Watches CloudKit for audio chunks uploaded by iPhone, transcribes them,
/// and triggers summarization when a meeting is complete.
@MainActor
final class RemoteMeetingProcessor {
    static let shared = RemoteMeetingProcessor()

    private let log = Logger.make("RemoteProcessor")
    private let transcriptionEngine = TranscriptionEngine()
    private var pollTimer: Timer?
    private var isProcessing = false

    private init() {}

    /// Start polling for remote audio chunks. Call once at app launch.
    func start() {
        log.info("RemoteMeetingProcessor started")

        // Prepare whisper model for remote transcription
        let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
        Task {
            do {
                try await transcriptionEngine.prepare(modelName: modelName)
                log.info("Remote transcription engine ready")
            } catch {
                log.error("Failed to prepare remote transcription engine: \(error)")
            }
        }

        // Poll every 15 seconds for new audio chunks
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollForChunks()
            }
        }
        // Also poll immediately
        Task { await pollForChunks() }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollForChunks() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let chunks = try await AudioChunkService.shared.fetchAllPendingChunks()
            guard !chunks.isEmpty else { return }
            log.info("Found \(chunks.count) pending audio chunks")

            // Group by meetingId
            let grouped = Dictionary(grouping: chunks) { $0["meetingId"] as? String ?? "" }
            for (meetingId, meetingChunks) in grouped {
                guard !meetingId.isEmpty else { continue }
                let sorted = meetingChunks.sorted { ($0["chunkIndex"] as? Int ?? 0) < ($1["chunkIndex"] as? Int ?? 0) }
                for chunk in sorted {
                    await processChunk(chunk, meetingId: meetingId)
                }
            }

            // Check if any meetings are ready for summarization
            await checkForCompletedMeetings()
        } catch {
            log.error("Poll failed: \(error)")
        }
    }

    private func processChunk(_ record: CKRecord, meetingId: String) async {
        let chunkIndex = record["chunkIndex"] as? Int ?? 0
        let offsetSeconds = record["offsetSeconds"] as? Double ?? 0
        log.info("Processing chunk \(chunkIndex) for meeting \(meetingId, privacy: .public)")

        do {
            // Download audio asset
            guard let audioURL = try AudioChunkService.shared.downloadAudioAsset(from: record) else {
                log.warning("No audio data in chunk \(chunkIndex)")
                return
            }
            defer { try? FileManager.default.removeItem(at: audioURL) }

            // Read raw Float32 samples
            let data = try Data(contentsOf: audioURL)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

            // Transcribe
            let segments = try await transcriptionEngine.transcribeRawAudio(
                samples: samples, meetingId: meetingId, offsetSeconds: offsetSeconds
            )

            // Save segments to local DB (syncs to iPhone via CKSyncEngine)
            for segment in segments {
                try? MeetingStore.shared.appendRemoteSegment(segment)
            }

            // Delete the audio chunk from CloudKit
            try await AudioChunkService.shared.markDoneAndDelete(recordID: record.recordID)
            log.info("Chunk \(chunkIndex) processed and deleted")
        } catch {
            log.error("Failed to process chunk \(chunkIndex): \(error)")
        }
    }

    /// Check if any meetings with status .transcribing have all chunks processed.
    private func checkForCompletedMeetings() async {
        let meetings = (try? MeetingStore.shared.fetchAll()) ?? []
        for meeting in meetings where meeting.status == .transcribing {
            do {
                // Check if any pending chunks remain
                let pending = try await AudioChunkService.shared.fetchPendingChunks(meetingId: meeting.id)
                guard pending.isEmpty else { continue }

                log.info("Meeting \(meeting.id, privacy: .public) — all chunks processed, finalizing")

                // Build raw transcript from all segments
                let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meeting.id)) ?? []
                let rawTranscript = segments
                    .sorted { $0.startSeconds < $1.startSeconds }
                    .map { "\($0.speaker): \($0.text)" }
                    .joined(separator: "\n")

                try MeetingStore.shared.finalizeMeeting(meeting.id, endedAt: Date(), rawTranscript: rawTranscript)

                // Summarize
                await SummaryEngine.shared.summarize(meetingId: meeting.id)
                await EmbeddingEngine.shared.embed(meetingId: meeting.id)

                log.info("Meeting \(meeting.id, privacy: .public) — summarized and done")
            } catch {
                log.error("Failed to finalize meeting \(meeting.id, privacy: .public): \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Add appendRemoteSegment to MeetingStore**

In `Memgram/Database/MeetingStore.swift`, add a method for saving segments from remote transcription (similar to `appendSegment` but takes a `MeetingSegment` directly instead of `TranscriptSegment`):

```swift
    func appendRemoteSegment(_ segment: MeetingSegment) throws {
        try db.write { db in
            var seg = segment
            try seg.insert(db)
        }
        sync?.enqueueSave(table: "segments", id: segment.id)
    }
```

- [ ] **Step 3: Start RemoteMeetingProcessor in AppDelegate**

In `Memgram/AppDelegate.swift`, in `applicationDidFinishLaunching`, after the CloudSync start block, add:

```swift
        // Start remote meeting processor (watches for iPhone audio chunks)
        RemoteMeetingProcessor.shared.start()
        appLog.info("RemoteMeetingProcessor started")
```

- [ ] **Step 4: Build Mac target**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10
```

- [ ] **Step 5: Commit**

```bash
git add Memgram/Sync/RemoteMeetingProcessor.swift Memgram/Database/MeetingStore.swift Memgram/AppDelegate.swift
git commit -m "feat: RemoteMeetingProcessor — polls CloudKit, transcribes chunks, summarizes on completion"
```

---

## Task 7: iPhone MobileRecordingView — Recording UI

**Files:**
- Create: `MemgramMobile/UI/MobileRecordingView.swift`
- Modify: `MemgramMobile/MemgramMobileApp.swift`

- [ ] **Step 1: Create MobileRecordingView**

Create `MemgramMobile/UI/MobileRecordingView.swift`:

```swift
import SwiftUI
import EventKit
import OSLog

private let log = Logger.make("UI")

struct MobileRecordingView: View {
    @ObservedObject private var recorder = MobileAudioRecorder.shared
    @ObservedObject private var uploader = AudioChunkUploader.shared
    @ObservedObject private var calendar = CalendarManager.shared
    @State private var liveSegments: [MeetingSegment] = []
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Calendar event card
                if !recorder.isRecording, let event = calendar.upcomingEvent {
                    upcomingEventCard(event: event)
                        .padding()
                }

                Spacer()

                // Status
                if recorder.isRecording {
                    recordingStatus
                } else {
                    idleStatus
                }

                Spacer()

                // Live transcript (during recording)
                if recorder.isRecording && !liveSegments.isEmpty {
                    liveTranscriptSection
                }

                // Record / Stop button
                recordButton
                    .padding(.bottom, 30)
            }
            .navigationTitle("Record")
            .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in
                loadLiveSegments()
            }
            .onAppear {
                if calendar.isEnabled {
                    Task { _ = await calendar.requestAccess() }
                    calendar.refreshUpcomingEvent()
                }
            }
        }
    }

    // MARK: - Subviews

    private func upcomingEventCard(event: EKEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text("Starting soon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(event.startDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(event.title ?? "Untitled Event")
                .font(.headline)
                .lineLimit(2)
            if let attendees = event.attendees, !attendees.isEmpty {
                Text(attendees.compactMap(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var recordingStatus: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text("Recording")
                .font(.title2.bold())
            Text(formatElapsed(recorder.elapsedSeconds))
                .font(.title.monospacedDigit())
                .foregroundStyle(.secondary)
            if uploader.pendingChunks > 0 {
                Label("Uploading \(uploader.pendingChunks) chunks…", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var idleStatus: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Ready to Record")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var liveTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Live Transcript")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(liveSegments.suffix(20), id: \.id) { seg in
                        Text(seg.text)
                            .font(.caption)
                            .padding(.horizontal)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Circle()
                .fill(recorder.isRecording ? .red : .blue)
                .frame(width: 72, height: 72)
                .overlay {
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white)
                            .frame(width: 24, height: 24)
                    } else {
                        Circle()
                            .fill(.white)
                            .frame(width: 28, height: 28)
                    }
                }
        }
    }

    // MARK: - Actions

    private func startRecording() {
        do {
            // Detect calendar event
            var calendarCtx: CalendarContext? = nil
            if calendar.isEnabled, let event = calendar.findEvent(around: Date()) {
                calendarCtx = calendar.context(for: event)
            }

            let title = calendarCtx?.eventTitle
                ?? "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            let meetingId = try uploader.startMeeting(title: title, calendarContext: calendarCtx)

            // Wire up chunk callback
            recorder.onChunkReady = { fileURL, index, offset in
                uploader.uploadChunk(fileURL: fileURL, chunkIndex: index, offsetSeconds: offset)
            }

            try recorder.start()
            log.info("Recording started for meeting \(meetingId, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            log.error("Failed to start recording: \(error)")
        }
    }

    private func stopRecording() {
        recorder.stop()
        Task {
            await uploader.finishRecording()
            log.info("Recording finished, meeting set to transcribing")
        }
    }

    private func loadLiveSegments() {
        guard let meetingId = uploader.currentMeetingId else { return }
        liveSegments = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
```

- [ ] **Step 2: Add Recording tab to MemgramMobileApp**

In `MemgramMobile/MemgramMobileApp.swift`, update the `TabView` to add a Recording tab and initialize CalendarManager:

In `init()`, add after CloudSync start:
```swift
        if CalendarManager.shared.isEnabled {
            Task {
                _ = await CalendarManager.shared.requestAccess()
                CalendarManager.shared.startMonitoring()
            }
        }
```

In the `TabView`, add the Recording tab between Meetings and Settings:
```swift
                MobileRecordingView()
                    .tabItem {
                        Label("Record", systemImage: "mic.fill")
                    }
```

- [ ] **Step 3: Build both targets**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug -destination "platform=macOS" build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -5
```

Fix any compile errors until both succeed.

- [ ] **Step 4: Commit**

```bash
git add MemgramMobile/
git commit -m "feat: iPhone recording view with live transcript, calendar integration, chunk upload"
```

---

## Task 8: Final Build Verification and Push

- [ ] **Step 1: Release build both targets**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Release -destination "platform=macOS" build 2>&1 | tail -5
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Release -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```

Expected: Both `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify Mac app still functions**

Launch Mac app from Xcode. Confirm:
- Meetings list loads
- Local recording works
- Summary generation works (Qwen streaming)
- RemoteMeetingProcessor logs "started" in Console

- [ ] **Step 3: Push**

```bash
git push
```
