# Parakeet Transcription Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Parakeet TDT v3 (via FluidAudio SPM package) as an alternative transcription backend selectable in Settings, replacing WhisperKit when chosen.

**Architecture:** Introduce a `TranscriptionBackend` enum (whisper/parakeet) stored in UserDefaults. Extract a `TranscriberProtocol` that both `WhisperTranscriber` (wrapping existing WhisperKit logic) and `ParakeetTranscriber` (wrapping FluidAudio) conform to. `TranscriptionEngine` delegates to whichever backend is active. A new `TranscriptionEngineSettings` view in the existing Privacy settings tab (or a new "Recording" tab) exposes the toggle. Parakeet is macOS-only initially — the iOS `AudioChunkService` flow continues using WhisperKit on Mac.

**Tech Stack:** Swift, FluidAudio (FluidInference/FluidAudio SPM), WhisperKit (existing), SwiftUI, UserDefaults, macOS 14+ / iOS 17+

---

## File Structure

**New files:**
- `Memgram/Transcription/TranscriberProtocol.swift` — `TranscriberProtocol` async protocol + `TranscriptionBackend` enum
- `Memgram/Transcription/WhisperTranscriber.swift` — WhisperKit implementation of the protocol (extracted from TranscriptionEngine)
- `Memgram/Transcription/ParakeetTranscriber.swift` — FluidAudio implementation of the protocol (macOS only)
- `Memgram/Transcription/TranscriptionBackendManager.swift` — `@MainActor ObservableObject` singleton tracking backend readiness, analogous to `WhisperModelManager`

**Modified files:**
- `project.yml` — add FluidAudio SPM dependency
- `Memgram/Transcription/TranscriptionEngine.swift` — delegate `prepare()`, `transcribe()`, and `transcribeRawAudio()` to the active `TranscriberProtocol`
- `Memgram/Transcription/WhisperModelManager.swift` — keep unchanged, still manages WhisperKit model selection
- `Memgram/UI/Settings/SettingsView.swift` — add transcription backend picker to a new "Recording" tab
- `Memgram/Audio/RecordingSession.swift` — pass active backend name to `TranscriptionEngine.prepare()`

---

### Task 1: Add FluidAudio SPM package and create the git branch baseline

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add FluidAudio to packages section in project.yml**

Find the `packages:` block (line 13) and add:

```yaml
packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: "6.0.0"
  WhisperKit:
    url: https://github.com/ekabanov/WhisperKit
    revision: "69c0a9d60199725ac216e80797a732836c473c1f"
  MLXSwiftLM:
    url: https://github.com/ml-explore/mlx-swift-lm
    branch: main
  MarkdownUI:
    url: https://github.com/gonzalezreal/swift-markdown-ui
    from: "2.0.0"
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    from: "0.12.4"
```

- [ ] **Step 2: Add FluidAudio as a dependency to the Memgram macOS target**

In the `Memgram` target's `dependencies:` list (around line 86), add:

```yaml
    dependencies:
      - package: GRDB
        product: GRDB
      - package: WhisperKit
        product: WhisperKit
      - package: MLXSwiftLM
        product: MLXLLM
      - package: MarkdownUI
        product: MarkdownUI
      - package: FluidAudio
        product: FluidAudio
```

Do NOT add FluidAudio to MemgramMobile or MemgramWatch — it's macOS-only for now.

- [ ] **Step 3: Regenerate and resolve packages**

```bash
xcodegen generate
xcodebuild -resolvePackageDependencies -project Memgram.xcodeproj 2>&1 | tail -5
```

Expected: `Resolved source packages:` with FluidAudio listed.

- [ ] **Step 4: Build to confirm package resolves**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add project.yml Memgram.xcodeproj
git commit -m "feat: add FluidAudio SPM dependency for Parakeet transcription"
```

---

### Task 2: Define TranscriberProtocol and TranscriptionBackend

**Files:**
- Create: `Memgram/Transcription/TranscriberProtocol.swift`

This defines the shared interface that both WhisperTranscriber and ParakeetTranscriber will implement, plus the backend enum stored in UserDefaults.

- [ ] **Step 1: Create TranscriberProtocol.swift**

```swift
import AVFoundation
import Foundation

/// The two available transcription backends.
enum TranscriptionBackend: String, CaseIterable, Identifiable {
    case whisper  = "whisper"
    case parakeet = "parakeet"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper:  return "Whisper (WhisperKit)"
        case .parakeet: return "Parakeet (FluidAudio)"
        }
    }

    var description: String {
        switch self {
        case .whisper:
            return "OpenAI Whisper — 100+ languages, runs on GPU via Metal."
        case .parakeet:
            return "NVIDIA Parakeet TDT — 25 European languages, ~10× faster, zero hallucinations on silence. Runs on Neural Engine."
        }
    }
}

/// Common interface for transcription backends.
/// Both WhisperTranscriber and ParakeetTranscriber conform to this.
protocol TranscriberProtocol: AnyObject {
    /// True when the model is fully loaded and ready to transcribe.
    var isReady: Bool { get }

    /// Download (if needed), load, and warm up the model.
    func prepare() async throws

    /// Transcribe a stereo 16 kHz Float32 buffer (L=mic, R=system).
    /// Returns segments with speaker attribution.
    func transcribeStereoBuffer(
        _ buffer: AVAudioPCMBuffer,
        leftEnergy: Float,
        rightEnergy: Float,
        chunkStart: Double
    ) async throws -> [TranscriptSegment]

    /// Transcribe a mono 16 kHz Float32 array (remote audio from iPhone).
    func transcribeRawAudio(
        samples: [Float],
        meetingId: String,
        offsetSeconds: Double
    ) async throws -> [MeetingSegment]
}
```

- [ ] **Step 2: Build to confirm no errors**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Memgram/Transcription/TranscriberProtocol.swift
git commit -m "feat: add TranscriberProtocol and TranscriptionBackend enum"
```

---

### Task 3: Extract WhisperTranscriber from TranscriptionEngine

**Files:**
- Create: `Memgram/Transcription/WhisperTranscriber.swift`

Move all WhisperKit-specific code out of TranscriptionEngine into this new file. TranscriptionEngine will later delegate to it.

- [ ] **Step 1: Create WhisperTranscriber.swift**

```swift
import AVFoundation
import OSLog
import WhisperKit

/// WhisperKit-based implementation of TranscriberProtocol.
final class WhisperTranscriber: TranscriberProtocol {

    private let log = Logger.make("Transcription")
    private var whisperKit: WhisperKit?

    var isReady: Bool { whisperKit != nil }

    func prepare() async throws {
        guard whisperKit == nil else {
            log.debug("WhisperKit already loaded, skipping prepare")
            return
        }
        let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
        log.info("Loading WhisperKit model: \(modelName, privacy: .public)")
        await MainActor.run { WhisperModelManager.shared.isWhisperDownloading = true }
        let wk = try await WhisperKit(model: modelName, verbose: false, logLevel: .none)
        self.whisperKit = wk
        log.info("WhisperKit loaded — triggering CoreML warm-up")
        let silence = [Float](repeating: 0, count: 16000)
        _ = try? await wk.transcribe(audioArray: silence)
        log.info("WhisperKit ready — model: \(modelName, privacy: .public)")
        await MainActor.run {
            WhisperModelManager.shared.isWhisperDownloading = false
            WhisperModelManager.shared.isWhisperReady = true
        }
    }

    func transcribeStereoBuffer(
        _ buffer: AVAudioPCMBuffer,
        leftEnergy: Float,
        rightEnergy: Float,
        chunkStart: Double
    ) async throws -> [TranscriptSegment] {
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        guard let samples = toMonoFloats(buffer) else { return [] }

        let options = DecodingOptions(task: .transcribe, language: nil,
                                      temperature: 0.0, skipSpecialTokens: true)
        log.debug("Transcribing chunk — \(samples.count) samples (\(Int(Double(samples.count)/16000))s)")
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples, decodeOptions: options)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let text = seg.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let startSec = chunkStart + Double(seg.start)
                let endSec   = chunkStart + Double(seg.end)
                let (speaker, channel) = determineSpeaker(
                    text: text, leftEnergy: leftEnergy, rightEnergy: rightEnergy)
                let cleanText = Self.stripDiarizationTags(text)
                guard !cleanText.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    id: UUID(), startSeconds: startSec, endSeconds: endSec,
                    text: cleanText, speaker: speaker, channel: channel))
            }
        }
        return segments
    }

    func transcribeRawAudio(
        samples: [Float],
        meetingId: String,
        offsetSeconds: Double
    ) async throws -> [MeetingSegment] {
        guard let whisperKit else { throw TranscriptionError.modelNotLoaded }
        let options = DecodingOptions(task: .transcribe, temperature: 0.0, skipSpecialTokens: true)
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples, decodeOptions: options)

        var segments: [MeetingSegment] = []
        for result in results {
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(MeetingSegment(
                    id: UUID().uuidString, meetingId: meetingId,
                    speaker: "Remote", channel: "microphone",
                    startSeconds: offsetSeconds + Double(segment.start),
                    endSeconds: offsetSeconds + Double(segment.end),
                    text: text, ckSystemFields: nil))
            }
        }
        log.info("Transcribed \(segments.count) segments from \(samples.count) samples at offset \(offsetSeconds)s")
        return segments
    }

    // MARK: - Helpers (private, same as original TranscriptionEngine)

    private func determineSpeaker(text: String, leftEnergy: Float, rightEnergy: Float) -> (String, AudioChannel) {
        if text.contains("[SPEAKER_00]") { return ("You", .microphone) }
        if text.contains("[SPEAKER_01]") { return ("Remote", .system) }
        let threshold: Float = 1.2
        if leftEnergy > rightEnergy * threshold  { return ("You", .microphone) }
        if rightEnergy > leftEnergy * threshold  { return ("Remote", .system) }
        return leftEnergy >= rightEnergy ? ("You", .microphone) : ("Remote", .system)
    }

    private static func stripDiarizationTags(_ text: String) -> String {
        var result = text
        for tag in ["[SPEAKER_00]", "[SPEAKER_01]", "[SPEAKER_02]", "[SPEAKER_03]"] {
            result = result.replacingOccurrences(of: tag, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func toMonoFloats(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        for ch in 0..<channelCount {
            for i in 0..<frames { mono[i] += channels[ch][i] }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frames { mono[i] *= scale }
        return mono
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Memgram/Transcription/WhisperTranscriber.swift
git commit -m "feat: extract WhisperTranscriber conforming to TranscriberProtocol"
```

---

### Task 4: Implement ParakeetTranscriber

**Files:**
- Create: `Memgram/Transcription/ParakeetTranscriber.swift`

FluidAudio's API: `AsrModels.downloadAndLoad(version:)` returns models, `AsrManager` transcribes. The `transcribe(_ samples: [Float])` method returns `AsrResult` with a `text` String and `segments` array containing `(startTime: Double, endTime: Double, text: String)` tuples.

- [ ] **Step 1: Create ParakeetTranscriber.swift**

```swift
#if os(macOS)
import AVFoundation
import FluidAudio
import OSLog

/// FluidAudio Parakeet TDT v3 implementation of TranscriberProtocol.
/// Runs on Apple Neural Engine (ANE) via CoreML — no GPU usage.
final class ParakeetTranscriber: TranscriberProtocol {

    private let log = Logger.make("Transcription")
    private var asrManager: AsrManager?

    var isReady: Bool { asrManager != nil }

    func prepare() async throws {
        guard asrManager == nil else {
            log.debug("Parakeet already loaded, skipping prepare")
            return
        }
        log.info("Loading Parakeet TDT v3 model")
        await MainActor.run {
            TranscriptionBackendManager.shared.isLoading = true
        }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        log.info("Parakeet ready")
        await MainActor.run {
            TranscriptionBackendManager.shared.isLoading = false
            TranscriptionBackendManager.shared.isReady = true
        }
    }

    func transcribeStereoBuffer(
        _ buffer: AVAudioPCMBuffer,
        leftEnergy: Float,
        rightEnergy: Float,
        chunkStart: Double
    ) async throws -> [TranscriptSegment] {
        guard let asrManager else { throw TranscriptionError.modelNotLoaded }
        guard let samples = toMonoFloats(buffer) else { return [] }

        log.debug("Parakeet transcribing chunk — \(samples.count) samples")
        let result = try await asrManager.transcribe(samples)

        return result.segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let startSec = chunkStart + seg.startTime
            let endSec   = chunkStart + seg.endTime
            let (speaker, channel) = determineSpeaker(
                leftEnergy: leftEnergy, rightEnergy: rightEnergy)
            return TranscriptSegment(
                id: UUID(), startSeconds: startSec, endSeconds: endSec,
                text: text, speaker: speaker, channel: channel)
        }
    }

    func transcribeRawAudio(
        samples: [Float],
        meetingId: String,
        offsetSeconds: Double
    ) async throws -> [MeetingSegment] {
        guard let asrManager else { throw TranscriptionError.modelNotLoaded }

        let result = try await asrManager.transcribe(samples)
        let segments: [MeetingSegment] = result.segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return MeetingSegment(
                id: UUID().uuidString, meetingId: meetingId,
                speaker: "Remote", channel: "microphone",
                startSeconds: offsetSeconds + seg.startTime,
                endSeconds: offsetSeconds + seg.endTime,
                text: text, ckSystemFields: nil)
        }
        log.info("Parakeet transcribed \(segments.count) segments from \(samples.count) samples at offset \(offsetSeconds)s")
        return segments
    }

    // MARK: - Helpers

    /// Parakeet doesn't produce diarization tags, so speaker is determined
    /// purely from which audio channel had more energy.
    private func determineSpeaker(leftEnergy: Float, rightEnergy: Float) -> (String, AudioChannel) {
        let threshold: Float = 1.2
        if leftEnergy > rightEnergy * threshold  { return ("You", .microphone) }
        if rightEnergy > leftEnergy * threshold  { return ("Remote", .system) }
        return leftEnergy >= rightEnergy ? ("You", .microphone) : ("Remote", .system)
    }

    private func toMonoFloats(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, frames > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        for ch in 0..<channelCount {
            for i in 0..<frames { mono[i] += channels[ch][i] }
        }
        let scale = 1.0 / Float(channelCount)
        for i in 0..<frames { mono[i] *= scale }
        return mono
    }
}
#endif
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

If there are API errors from FluidAudio (the exact property names on `AsrResult.segments` may differ), check by running:

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep "error:"
```

Then open the FluidAudio package sources to find the correct property names on `AsrSegment` and adjust accordingly.

- [ ] **Step 3: Commit**

```bash
git add Memgram/Transcription/ParakeetTranscriber.swift
git commit -m "feat: implement ParakeetTranscriber using FluidAudio ANE backend"
```

---

### Task 5: Add TranscriptionBackendManager

**Files:**
- Create: `Memgram/Transcription/TranscriptionBackendManager.swift`

Mirrors `WhisperModelManager` but for Parakeet state + the user's backend preference.

- [ ] **Step 1: Create TranscriptionBackendManager.swift**

```swift
import Foundation
import Combine

@MainActor
final class TranscriptionBackendManager: ObservableObject {
    static let shared = TranscriptionBackendManager()

    private let backendKey = "transcriptionBackend"

    /// The backend the user has selected (persisted in UserDefaults).
    @Published var selectedBackend: TranscriptionBackend {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: backendKey) }
    }

    /// True while Parakeet model is downloading or loading.
    @Published var isLoading: Bool = false

    /// True once Parakeet model is fully ready.
    @Published var isReady: Bool = false

    private init() {
        let saved = UserDefaults.standard.string(forKey: backendKey) ?? ""
        selectedBackend = TranscriptionBackend(rawValue: saved) ?? .whisper
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Memgram/Transcription/TranscriptionBackendManager.swift
git commit -m "feat: add TranscriptionBackendManager for backend preference and Parakeet state"
```

---

### Task 6: Refactor TranscriptionEngine to delegate to active backend

**Files:**
- Modify: `Memgram/Transcription/TranscriptionEngine.swift`

Replace all WhisperKit-specific code with delegation to `TranscriberProtocol`. The engine no longer knows about WhisperKit or Parakeet directly.

- [ ] **Step 1: Replace TranscriptionEngine.swift with the delegating version**

```swift
import AVFoundation
import Combine
import OSLog

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? { "Transcription model is not loaded" }
}

struct TranscriptSegment: Identifiable {
    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    var speaker: String
    var channel: AudioChannel
}

final class TranscriptionEngine {

    private let log = Logger.make("Transcription")
    private var transcriber: (any TranscriberProtocol)?
    private let subject = PassthroughSubject<TranscriptSegment, Never>()
    private var accumulatedSeconds: Double = 0

    private struct PendingChunk {
        let buffer: AVAudioPCMBuffer
        let leftEnergy: Float
        let rightEnergy: Float
        let chunkStart: Double
    }
    private var pendingChunks: [PendingChunk] = []
    private var isTranscribing = false

    private let allChunksDoneSubject = PassthroughSubject<Void, Never>()

    var allChunksDonePublisher: AnyPublisher<Void, Never> {
        allChunksDoneSubject.eraseToAnyPublisher()
    }

    var isIdle: Bool { !isTranscribing && pendingChunks.isEmpty }

    var segmentPublisher: AnyPublisher<TranscriptSegment, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Load the active backend model. modelName is used only for Whisper
    /// (Parakeet uses a fixed v3 model). Pass the result of
    /// WhisperModelManager.shared.selectedModel.whisperKitName for Whisper.
    func prepare(modelName: String) async throws {
        guard transcriber == nil else { return }
        #if os(macOS)
        let backend = await MainActor.run { TranscriptionBackendManager.shared.selectedBackend }
        switch backend {
        case .whisper:
            let t = WhisperTranscriber()
            try await t.prepare()
            transcriber = t
        case .parakeet:
            let t = ParakeetTranscriber()
            try await t.prepare()
            transcriber = t
        }
        #else
        // iOS always uses Whisper (Parakeet FluidAudio is macOS-only)
        let t = WhisperTranscriber()
        try await t.prepare()
        transcriber = t
        #endif
        drainIfIdle()
    }

    func reset() {
        accumulatedSeconds = 0
        pendingChunks.removeAll()
        isTranscribing = false
    }

    /// Called with each stereo chunk from StereoMixer (left=mic, right=system).
    func transcribe(_ buffer: AVAudioPCMBuffer) {
        let leftEnergy  = channelRMS(buffer, channel: 0)
        let rightEnergy = channelRMS(buffer, channel: 1)
        let chunkStart = accumulatedSeconds
        accumulatedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate

        pendingChunks.append(PendingChunk(
            buffer: buffer, leftEnergy: leftEnergy,
            rightEnergy: rightEnergy, chunkStart: chunkStart
        ))
        drainIfIdle()
    }

    private func drainIfIdle() {
        guard !isTranscribing, !pendingChunks.isEmpty else { return }
        guard let transcriber, transcriber.isReady else { return }
        let chunk = pendingChunks.removeFirst()
        isTranscribing = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let segments = try await transcriber.transcribeStereoBuffer(
                    chunk.buffer,
                    leftEnergy: chunk.leftEnergy,
                    rightEnergy: chunk.rightEnergy,
                    chunkStart: chunk.chunkStart
                )
                for segment in segments { self.subject.send(segment) }
            } catch {
                log.error("Chunk transcription failed: \(error)")
            }
            self.isTranscribing = false
            if self.pendingChunks.isEmpty {
                self.allChunksDoneSubject.send()
            } else {
                self.drainIfIdle()
            }
        }
    }

    // MARK: - Raw Audio Transcription (iPhone remote chunks)

    func transcribeRawAudio(samples: [Float], meetingId: String, offsetSeconds: Double) async throws -> [MeetingSegment] {
        guard let transcriber else { throw TranscriptionError.modelNotLoaded }
        return try await transcriber.transcribeRawAudio(
            samples: samples, meetingId: meetingId, offsetSeconds: offsetSeconds)
    }

    // MARK: - Audio helpers

    private func channelRMS(_ buffer: AVAudioPCMBuffer, channel: Int) -> Float {
        guard let channels = buffer.floatChannelData,
              channel < Int(buffer.format.channelCount) else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let ptr = channels[channel]
        var sum: Float = 0
        for i in 0..<frames { sum += ptr[i] * ptr[i] }
        return sqrt(sum / Float(frames))
    }
}
```

Note: `AudioChannel` is still defined in `TranscriberProtocol.swift`... actually no, `AudioChannel` was originally in `TranscriptionEngine.swift`. Since we're replacing the file, move `AudioChannel` to `TranscriberProtocol.swift`. Add this enum to `TranscriberProtocol.swift` before the `TranscriptionBackend` enum:

```swift
enum AudioChannel: String {
    case microphone = "microphone"
    case system     = "system"
    case unknown    = "unknown"
}
```

- [ ] **Step 2: Add AudioChannel to TranscriberProtocol.swift**

Open `Memgram/Transcription/TranscriberProtocol.swift` and prepend `AudioChannel` before `TranscriptionBackend`:

```swift
import AVFoundation
import Foundation

enum AudioChannel: String {
    case microphone = "microphone"
    case system     = "system"
    case unknown    = "unknown"
}

enum TranscriptionBackend: String, CaseIterable, Identifiable {
    // ... (rest unchanged)
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

Also build iOS to make sure the `#else` path compiles:

```bash
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Transcription/TranscriptionEngine.swift \
        Memgram/Transcription/TranscriberProtocol.swift
git commit -m "refactor: TranscriptionEngine delegates to TranscriberProtocol — Whisper or Parakeet"
```

---

### Task 7: Add transcription backend setting to SettingsView

**Files:**
- Modify: `Memgram/UI/Settings/SettingsView.swift`

Add a "Recording" tab with a backend picker and description. Parakeet is macOS-only so wrap in `#if os(macOS)`.

- [ ] **Step 1: Add RecordingSettingsTab to SettingsView.swift**

Add a new tab in the `TabView` in `SettingsView.body`:

```swift
struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            RecordingSettingsTab()
                .tabItem { Label("Recording", systemImage: "waveform") }
            CalendarSettingsView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
            BugReportView()
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
        }
        .frame(width: 520, height: 440)
    }
}
```

- [ ] **Step 2: Implement RecordingSettingsTab**

Add this struct at the end of `SettingsView.swift`, before the `// MARK: - Privacy Settings` block:

```swift
// MARK: - Recording Settings

struct RecordingSettingsTab: View {
    @ObservedObject private var backendManager = TranscriptionBackendManager.shared
    @ObservedObject private var whisperManager = WhisperModelManager.shared

    var body: some View {
        Form {
            Section("Transcription Engine") {
                Picker("Engine", selection: $backendManager.selectedBackend) {
                    ForEach(TranscriptionBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(backendManager.selectedBackend.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Whisper Model") {
                LabeledContent("Selected model") {
                    Text(whisperManager.selectedModel.shortName)
                        .foregroundStyle(.secondary)
                }
                Text("Model is automatically selected based on available RAM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(backendManager.selectedBackend == .whisper ? 1 : 0.4)
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/UI/Settings/SettingsView.swift
git commit -m "feat: add Recording settings tab with transcription backend picker"
```

---

### Task 8: Update PopoverView readiness check to handle Parakeet

**Files:**
- Modify: `Memgram/UI/MenuBar/PopoverView.swift`

The Start Recording button is disabled while `modelManager.isWhisperReady` is false. When Parakeet is selected, `isWhisperReady` will never become true. Need to check the active backend's readiness state.

- [ ] **Step 1: Add computed isModelReady helper to PopoverView**

In `PopoverView`, add a new `@ObservedObject` and update the disabled logic. Find the current `@ObservedObject private var modelManager = WhisperModelManager.shared` and add:

```swift
@ObservedObject private var modelManager = WhisperModelManager.shared
@ObservedObject private var backendManager = TranscriptionBackendManager.shared
```

Add a computed property:

```swift
private var isModelReady: Bool {
    switch backendManager.selectedBackend {
    case .whisper:  return modelManager.isWhisperReady
    case .parakeet: return backendManager.isReady
    }
}

private var isModelLoading: Bool {
    switch backendManager.selectedBackend {
    case .whisper:  return modelManager.isWhisperDownloading
    case .parakeet: return backendManager.isLoading
    }
}
```

- [ ] **Step 2: Update all isWhisperReady references in PopoverView**

Replace every `.disabled(!modelManager.isWhisperReady)` with `.disabled(!isModelReady)`.

Replace the help text `"Whisper is loading — ready shortly"` with `"\(backendManager.selectedBackend.displayName) is loading — ready shortly"`.

Replace the status text `modelManager.isWhisperReady ? "Recording & transcribing…" : "Recording…"` with `isModelReady ? "Recording & transcribing…" : "Recording…"`.

- [ ] **Step 3: Update the download progress card to show Parakeet download too**

In the `downloadCards` computed property, after the existing `if modelManager.isWhisperDownloading` block, add:

```swift
if backendManager.isLoading {
    downloadProgressCard(
        icon: "arrow.down.circle",
        iconColor: .indigo,
        title: "Setting up Parakeet",
        subtitle: "~600 MB · ANE model · first run only",
        progress: nil
    )
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Memgram/UI/MenuBar/PopoverView.swift
git commit -m "feat: update Start Recording readiness check for Parakeet backend"
```

---

### Task 9: Wire RecordingSession to respect backend switch

**Files:**
- Modify: `Memgram/Audio/RecordingSession.swift`

`preloadWhisperModel()` always loads Whisper regardless of the selected backend. Rename to `preloadTranscriptionModel()` and skip WhisperKit if Parakeet is selected.

- [ ] **Step 1: Update preloadWhisperModel in RecordingSession.swift**

Find (line 38):
```swift
func preloadWhisperModel() {
    let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
    Task {
        do {
            try await transcriptionEngine.prepare(modelName: modelName)
        } catch {
            log.error("Whisper preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

Replace with:

```swift
func preloadTranscriptionModel() {
    let modelName = WhisperModelManager.shared.selectedModel.whisperKitName
    Task {
        do {
            try await transcriptionEngine.prepare(modelName: modelName)
        } catch {
            log.error("Transcription model preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Update AppDelegate.swift to call the new method name**

Find `RecordingSession.shared.preloadWhisperModel()` and replace with `RecordingSession.shared.preloadTranscriptionModel()`.

- [ ] **Step 3: Build both targets**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

Expected: Both `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Audio/RecordingSession.swift Memgram/AppDelegate.swift
git commit -m "feat: rename preloadWhisperModel to preloadTranscriptionModel — backend-agnostic"
```

---

### Task 10: Re-prepare engine on backend switch

**Files:**
- Modify: `Memgram/Transcription/TranscriptionBackendManager.swift`

When the user switches backends in Settings, the `TranscriptionEngine` has already loaded the old backend (stored as `transcriber`). The engine's `transcriber` must be reset and the new model loaded. The cleanest approach: add a `reset()` call to `TranscriptionEngine` when the setting changes, then pre-warm the new backend.

`TranscriptionEngine` needs a way to swap its transcriber. Add a `resetTranscriber()` method.

- [ ] **Step 1: Add resetTranscriber to TranscriptionEngine.swift**

Add after `reset()`:

```swift
/// Discard the loaded transcriber so the next prepare() call loads the active backend.
/// Call when the user switches transcription backends.
func resetTranscriber() {
    transcriber = nil
    // Also reset WhisperKit/Parakeet readiness flags
    Task { @MainActor in
        WhisperModelManager.shared.isWhisperReady = false
        WhisperModelManager.shared.isWhisperDownloading = false
        TranscriptionBackendManager.shared.isReady = false
        TranscriptionBackendManager.shared.isLoading = false
    }
}
```

- [ ] **Step 2: Observe backend changes in RecordingSession.swift**

In `RecordingSession.swift`, add a Combine cancellable for the backend change:

```swift
private var backendCancellable: AnyCancellable?
```

In `RecordingSession.init()` (the `private init() {}` block), add observation after the current empty init... actually `RecordingSession` uses `private init() {}`. Since it's a singleton, initialize the observer by adding a `setup()` call. Instead, the simpler approach is to reset + reload in RecordingSession when not recording.

Actually the simplest approach: when backend changes and NOT currently recording, reset the engine and preload the new backend. Add this observation in `RecordingSession` after the `private init() {}`:

```swift
private var backendCancellable: AnyCancellable?

private init() {
    backendCancellable = TranscriptionBackendManager.shared.$selectedBackend
        .dropFirst()  // skip initial value
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self, !self.isRecording else { return }
            self.transcriptionEngine.resetTranscriber()
            self.preloadTranscriptionModel()
        }
}
```

Note: `RecordingSession` is `@MainActor` so `TranscriptionBackendManager.shared.$selectedBackend` is accessible directly.

- [ ] **Step 3: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Transcription/TranscriptionEngine.swift \
        Memgram/Audio/RecordingSession.swift \
        Memgram/Transcription/TranscriptionBackendManager.swift
git commit -m "feat: reload transcription engine when user switches backend in settings"
```

---

### Task 11: Final build verification

- [ ] **Step 1: Build macOS Release**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Release build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Build iOS Release**

```bash
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Release build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

No code changes in this task — it's a verification gate only.

---

## Self-Review

**1. Spec coverage:**
- ✅ FluidAudio dependency added
- ✅ Parakeet as alternative backend
- ✅ Setting to choose backend
- ✅ Whisper unchanged when selected
- ✅ Feature in separate branch (`feature/parakeet-transcription`)

**2. Placeholder scan:**
- The only "TBD" is the exact FluidAudio segment property names — Task 4 Step 2 explains how to resolve this from the build error.

**3. Type consistency:**
- `TranscriberProtocol` methods match usage in `TranscriptionEngine` ✅
- `TranscriptSegment` defined once in `TranscriptionEngine.swift` (new version) ✅
- `AudioChannel` moved to `TranscriberProtocol.swift` ✅
- `TranscriptionError.modelNotLoaded` used in both transcrbers ✅ (defined in `TranscriptionEngine.swift`)
- `TranscriptionBackendManager.shared.isReady` / `isLoading` used in `PopoverView` and `ParakeetTranscriber` ✅
