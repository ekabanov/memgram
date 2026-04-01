# Smart Channel Diarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the binary You/Remote speaker attribution with proper multi-speaker diarization (Room 1/2, Remote 1/2), while also eliminating transcript doubling by feeding only the dominant audio channel to the transcription engine.

**Architecture:** Three coordinated changes: (1) channel selection replaces naive L+R averaging in both transcription backends — the dominant channel is used so echo doesn't reinforce the transcript; (2) a new `SpeakerDiarizer` runs two `SortformerDiarizer` instances (one for mic, one for system audio) on accumulated audio after each recording, producing per-channel speaker timelines; (3) after transcription drains, speaker labels on all segments are updated using the diarizer timelines with echo suppression — mic segments that occurred while system audio was dominant are attributed to the remote speaker instead of an in-room one.

**Tech Stack:** Swift, FluidAudio `SortformerDiarizer` (.balancedV2_1 config), GRDB, macOS 14+

---

## File Structure

**New files:**
- `Memgram/Transcription/AudioChannelUtils.swift` — `selectDominantChannel(buffer:leftEnergy:rightEnergy:)` shared utility used by both transcription backends
- `Memgram/Transcription/SpeakerDiarizer.swift` — macOS-only; accumulates per-channel audio during recording, runs batch diarization after, resolves speaker labels with echo suppression

**Modified files:**
- `Memgram/Transcription/WhisperTranscriber.swift` — replace `toMonoFloats` with `selectDominantChannel`
- `Memgram/Transcription/ParakeetTranscriber.swift` — replace `toMonoFloats` with `selectDominantChannel`
- `Memgram/Database/MeetingStore.swift` — add `updateSegmentSpeaker(id:speaker:)` for post-diarization label rewrite
- `Memgram/Audio/RecordingSession.swift` — create SpeakerDiarizer on start, feed it each stereo chunk, run diarization in the finalize closure after transcription drains

---

### Task 1: Add AudioChannelUtils.swift — dominant channel selection

**Files:**
- Create: `Memgram/Transcription/AudioChannelUtils.swift`

This replaces the naive `(L+R)/2` mix with energy-based channel selection. When one channel is clearly louder (threshold 1.2×), use only that channel's audio. When both channels are at similar levels (ambient/silence), average them.

- [ ] **Step 1: Create the file**

```swift
import AVFoundation

/// Extract audio from the dominant channel of a stereo 16 kHz buffer.
///
/// - If mic (L) energy exceeds system (R) energy by `threshold`, return mic only.
/// - If system (R) energy exceeds mic (L) energy by `threshold`, return system only.
/// - Otherwise return the average of both channels.
///
/// This prevents echo reinforcement: when a remote speaker's voice leaks through
/// room speakers into the mic, selecting only the system channel for transcription
/// avoids the doubled/louder signal that causes duplicate transcript segments.
func selectDominantChannel(
    _ buffer: AVAudioPCMBuffer,
    leftEnergy: Float,
    rightEnergy: Float,
    threshold: Float = 1.2
) -> [Float]? {
    guard let channels = buffer.floatChannelData else { return nil }
    let frames = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard channelCount >= 1, frames > 0 else { return nil }

    // Single-channel buffer — just return it
    if channelCount == 1 {
        return Array(UnsafeBufferPointer(start: channels[0], count: frames))
    }

    // Two-channel: pick dominant or average
    let left  = Array(UnsafeBufferPointer(start: channels[0], count: frames))
    let right = Array(UnsafeBufferPointer(start: channels[1], count: frames))

    if leftEnergy  > rightEnergy * threshold { return left }
    if rightEnergy > leftEnergy  * threshold { return right }

    // Neither clearly dominant — average
    var mono = [Float](repeating: 0, count: frames)
    for i in 0..<frames { mono[i] = (left[i] + right[i]) * 0.5 }
    return mono
}
```

- [ ] **Step 2: Register with xcodegen and build**

```bash
cd /Users/jevgenikabanov/Documents/Projects/Claude/Memgram
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Memgram/Transcription/AudioChannelUtils.swift Memgram.xcodeproj
git commit -m "feat: add selectDominantChannel utility — suppress echo in transcription input"
```

---

### Task 2: Update WhisperTranscriber to use dominant channel

**Files:**
- Modify: `Memgram/Transcription/WhisperTranscriber.swift`

Replace `guard let samples = toMonoFloats(buffer) else { return [] }` with `selectDominantChannel`.

- [ ] **Step 1: Read the current transcribeStereoBuffer in WhisperTranscriber.swift**

- [ ] **Step 2: Replace toMonoFloats with selectDominantChannel**

Find this line in `transcribeStereoBuffer`:
```swift
guard let samples = toMonoFloats(buffer) else { return [] }
```

Replace with:
```swift
guard let samples = selectDominantChannel(buffer, leftEnergy: leftEnergy, rightEnergy: rightEnergy) else { return [] }
```

- [ ] **Step 3: Remove the now-unused toMonoFloats method from WhisperTranscriber**

Delete the entire `private func toMonoFloats(_ buffer: AVAudioPCMBuffer) -> [Float]?` method (it was lines 113–125 approximately). The shared `selectDominantChannel` function from `AudioChannelUtils.swift` replaces it.

- [ ] **Step 4: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Memgram/Transcription/WhisperTranscriber.swift
git commit -m "feat: WhisperTranscriber uses dominant channel selection instead of L+R mix"
```

---

### Task 3: Update ParakeetTranscriber to use dominant channel

**Files:**
- Modify: `Memgram/Transcription/ParakeetTranscriber.swift`

Same change as Task 2 but for Parakeet.

- [ ] **Step 1: Read the current transcribeStereoBuffer in ParakeetTranscriber.swift**

- [ ] **Step 2: Replace toMonoFloats call with selectDominantChannel**

In `transcribeStereoBuffer`, find:
```swift
guard let monoSamples = toMonoFloats(buffer) else { return [] }
```

Replace with:
```swift
guard let monoSamples = selectDominantChannel(buffer, leftEnergy: leftEnergy, rightEnergy: rightEnergy) else { return [] }
```

Then remove the `private func toMonoFloats` method from the file (lines ~132–144).

- [ ] **Step 3: Build both targets**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3
```

Expected: both `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Transcription/ParakeetTranscriber.swift
git commit -m "feat: ParakeetTranscriber uses dominant channel selection instead of L+R mix"
```

---

### Task 4: Add updateSegmentSpeaker to MeetingStore

**Files:**
- Modify: `Memgram/Database/MeetingStore.swift`

Post-diarization, we need to update speaker labels on individual segments. Read `MeetingStore.swift` first to find where to insert the new method.

- [ ] **Step 1: Read MeetingStore.swift to find the right insertion point**

- [ ] **Step 2: Add updateSegmentSpeaker after appendSegment / appendRemoteSegment**

```swift
/// Update the speaker label on a single transcript segment after diarization.
func updateSegmentSpeaker(id: String, speaker: String) throws {
    try db.write { db in
        try db.execute(
            sql: "UPDATE segments SET speaker = ? WHERE id = ?",
            arguments: [speaker, id]
        )
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Database/MeetingStore.swift
git commit -m "feat: add MeetingStore.updateSegmentSpeaker for post-diarization label rewrite"
```

---

### Task 5: Create SpeakerDiarizer

**Files:**
- Create: `Memgram/Transcription/SpeakerDiarizer.swift`

This is the core of the diarization feature. It accumulates per-channel audio from each stereo chunk during recording, runs `SortformerDiarizer.processComplete` on both channels after recording ends, and resolves each transcript segment's speaker label using the resulting timelines plus echo suppression.

Key FluidAudio API facts (verified from source):
- `import FluidAudio`
- `SortformerDiarizer(config: .balancedV2_1, timelineConfig: .sortformerDefault)`
- `SortformerModels.loadFromHuggingFace(config: .balancedV2_1) async throws -> SortformerModels`
- `diarizer.initialize(models: SortformerModels)`
- `diarizer.processComplete(_ samples: [Float], sourceSampleRate: Double?) throws -> DiarizerTimeline`
- `DiarizerTimeline.speakers: [Int: DiarizerSpeaker]`
- `DiarizerSpeaker.finalizedSegments: [DiarizerSegment]`
- `DiarizerSegment.startTime: Float`, `DiarizerSegment.endTime: Float`

- [ ] **Step 1: Create the file**

```swift
#if os(macOS)
import AVFoundation
import FluidAudio
import OSLog

/// Runs two SortformerDiarizer instances (one for mic, one for system audio)
/// on audio accumulated during a recording session. After the recording ends,
/// resolves transcript segment speaker labels with echo suppression:
/// mic segments that occurred while system audio was dominant are attributed
/// to the active remote speaker rather than an in-room speaker.
@available(macOS 14.0, *)
final class SpeakerDiarizer {

    private let log = Logger.make("Diarizer")

    // Accumulated audio for each channel
    private var micSamples:  [Float] = []
    private var sysSamples:  [Float] = []

    // Per-chunk energy records for echo suppression
    private struct EnergyRecord {
        let startSec: Double
        let endSec:   Double
        let micEnergy: Float
        let sysEnergy: Float
    }
    private var energyLog: [EnergyRecord] = []
    private var accumulatedSec: Double = 0

    // Loaded SortformerModels (shared between both diarizers to save memory)
    private var models: SortformerModels?

    // MARK: - Lifecycle

    /// Download and load SortformerModels. Safe to call multiple times — no-op if already loaded.
    func prepare() async throws {
        guard models == nil else { return }
        log.info("[Diarizer] Downloading/loading SortformerModels (.balancedV2_1)...")
        models = try await SortformerModels.loadFromHuggingFace(config: .balancedV2_1)
        log.info("[Diarizer] Models ready")
    }

    /// Reset accumulated audio (call at the start of each recording).
    func reset() {
        micSamples.removeAll()
        sysSamples.removeAll()
        energyLog.removeAll()
        accumulatedSec = 0
    }

    /// Accumulate a stereo chunk from StereoMixer (L=mic, R=system).
    /// Called from RecordingSession for every chunk during recording.
    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData,
              buffer.format.channelCount >= 2 else { return }

        let left  = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        let right = Array(UnsafeBufferPointer(start: channels[1], count: frames))

        let startSec = accumulatedSec
        accumulatedSec += Double(frames) / StereoMixer.sampleRate

        micSamples.append(contentsOf: left)
        sysSamples.append(contentsOf: right)
        energyLog.append(EnergyRecord(
            startSec: startSec, endSec: accumulatedSec,
            micEnergy: rms(left), sysEnergy: rms(right)
        ))
    }

    // MARK: - Diarization

    /// Run batch diarization on the accumulated audio.
    /// Returns a closure that resolves a speaker label for a given segment.
    /// Falls back to the original You/Remote labels if diarization fails or
    /// if no audio has been accumulated.
    func runAndResolve(segments: [TranscriptSegment]) async -> [String: String] {
        guard !micSamples.isEmpty, let models else {
            log.warning("[Diarizer] Skipping — no audio accumulated or models not loaded")
            return [:]
        }

        do {
            log.info("[Diarizer] Running mic diarizer on \(self.micSamples.count) samples...")
            let micDiarizer = SortformerDiarizer(config: .balancedV2_1,
                                                 timelineConfig: .sortformerDefault)
            micDiarizer.initialize(models: models)
            let micTimeline = try micDiarizer.processComplete(
                micSamples, sourceSampleRate: StereoMixer.sampleRate)
            log.info("[Diarizer] Mic diarizer: \(micTimeline.speakers.count) speaker(s)")

            log.info("[Diarizer] Running system diarizer on \(self.sysSamples.count) samples...")
            let sysDiarizer = SortformerDiarizer(config: .balancedV2_1,
                                                 timelineConfig: .sortformerDefault)
            sysDiarizer.initialize(models: models)
            let sysTimeline = try sysDiarizer.processComplete(
                sysSamples, sourceSampleRate: StereoMixer.sampleRate)
            log.info("[Diarizer] System diarizer: \(sysTimeline.speakers.count) speaker(s)")

            // Build id→label map for all segments
            var result: [String: String] = [:]
            for segment in segments {
                result[segment.id.uuidString] = resolve(
                    segment: segment,
                    micTimeline: micTimeline,
                    sysTimeline: sysTimeline
                )
            }
            return result
        } catch {
            log.error("[Diarizer] Failed: \(error)")
            return [:]
        }
    }

    // MARK: - Speaker Resolution

    private func resolve(
        segment: TranscriptSegment,
        micTimeline: DiarizerTimeline,
        sysTimeline: DiarizerTimeline
    ) -> String {
        let midSec = (segment.startSeconds + segment.endSeconds) / 2

        // Energy at this segment's time window (nearest chunk)
        let energy = energyLog.first {
            $0.startSec <= midSec && $0.endSec > midSec
        } ?? EnergyRecord(startSec: 0, endSec: 0, micEnergy: 0, sysEnergy: 0)

        if segment.channel == .system {
            // System audio channel — always use sys diarizer
            return speakerLabel(in: sysTimeline, atSec: midSec, prefix: "Remote")
        } else {
            // Mic channel — apply echo suppression
            // If system audio was dominant during this segment, it's likely echo
            if energy.sysEnergy > energy.micEnergy * 1.2 {
                return speakerLabel(in: sysTimeline, atSec: midSec, prefix: "Remote")
            }
            return speakerLabel(in: micTimeline, atSec: midSec, prefix: "Room")
        }
    }

    private func speakerLabel(
        in timeline: DiarizerTimeline,
        atSec: Double,
        prefix: String
    ) -> String {
        let t = Float(atSec)
        for (_, speaker) in timeline.speakers {
            for seg in speaker.finalizedSegments where seg.startTime <= t && seg.endTime >= t {
                return "\(prefix) \(speaker.index + 1)"
            }
        }
        // No speaker found at this time — return default label
        return prefix
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }
}
#endif
```

- [ ] **Step 2: Register and build**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20
```

Expected: `** BUILD SUCCEEDED **`

If there are FluidAudio API errors (e.g., `SortformerDiarizer.initialize(models:)` not found), check the actual signature:
```bash
grep -n "func initialize" ~/Library/Developer/Xcode/DerivedData/Memgram-*/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Sortformer/SortformerDiarizer.swift
```

And adjust accordingly. The `processComplete` signature requires `sourceSampleRate` to be `Double?` — pass `StereoMixer.sampleRate` (a `Double` constant = 16000.0).

- [ ] **Step 3: Commit**

```bash
git add Memgram/Transcription/SpeakerDiarizer.swift Memgram.xcodeproj
git commit -m "feat: add SpeakerDiarizer — dual-channel Sortformer with echo suppression"
```

---

### Task 6: Wire SpeakerDiarizer into RecordingSession

**Files:**
- Modify: `Memgram/Audio/RecordingSession.swift`

Wire the diarizer into the recording lifecycle: create on start, feed chunks, run in finalize, update segment speaker labels.

- [ ] **Step 1: Read RecordingSession.swift — all of it**

- [ ] **Step 2: Add speakerDiarizer property**

After the existing `private var finalizationCancellable: AnyCancellable?` line, add:

```swift
#if os(macOS)
private let speakerDiarizer: SpeakerDiarizer? = {
    if #available(macOS 14.0, *) { return SpeakerDiarizer() }
    return nil
}()
#endif
```

- [ ] **Step 3: Preload diarizer models in preloadTranscriptionModel()**

In `preloadTranscriptionModel()`, after the transcription engine prepare Task, add:

```swift
#if os(macOS)
if #available(macOS 14.0, *) {
    Task {
        do { try await speakerDiarizer?.prepare() }
        catch { log.error("Diarizer preload failed: \(error.localizedDescription, privacy: .public)") }
    }
}
#endif
```

- [ ] **Step 4: Reset and feed diarizer in start()**

In `start()`, after `transcriptionEngine.reset()` and `segments = []`, add:

```swift
#if os(macOS)
if #available(macOS 14.0, *) { speakerDiarizer?.reset() }
#endif
```

Then, in the `chunkCancellable = mixer.chunkPublisher.sink { ... }` block, after `self?.transcriptionEngine.transcribe(chunk)`, add:

```swift
#if os(macOS)
if #available(macOS 14.0, *) { self?.speakerDiarizer?.append(chunk) }
#endif
```

- [ ] **Step 5: Run diarization in the finalize closure**

In the `finalize` closure, find the section that builds `rawTranscript` and calls `finalizeMeeting`. After the transcript segments are available but before `finalizeMeeting` is called, add the diarization step:

Find:
```swift
let rawTranscript = self.segments
    .map { "\($0.speaker): \($0.text)" }
    .joined(separator: "\n")
self.log.info("Finalising meeting ...")
do { try MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript) }
```

Replace with:

```swift
// Run diarization if available and update speaker labels
#if os(macOS)
if #available(macOS 14.0, *), let diarizer = self.speakerDiarizer {
    let labelMap = await diarizer.runAndResolve(segments: self.segments)
    if !labelMap.isEmpty {
        // Update in-memory segments
        for i in self.segments.indices {
            if let label = labelMap[self.segments[i].id.uuidString] {
                self.segments[i].speaker = label
            }
        }
        // Update DB segments
        for segment in self.segments {
            if let label = labelMap[segment.id.uuidString] {
                try? MeetingStore.shared.updateSegmentSpeaker(
                    id: segment.id.uuidString, speaker: label)
            }
        }
        self.log.info("Diarization complete — updated \(labelMap.count) segment speaker labels")
    }
}
#endif

let rawTranscript = self.segments
    .map { "\($0.speaker): \($0.text)" }
    .joined(separator: "\n")
self.log.info("Finalising meeting ...")
do { try MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript) }
```

**Important note:** The `finalize` closure is currently a non-async closure called via `.sink`. To use `await diarizer.runAndResolve(...)`, you'll need to wrap the finalize block body in an async context. The current pattern uses `Task { ... }` at the end. Restructure the finalize closure to be async:

The current `finalize` is a `let finalize = { [weak self] in ... }`. Change it to use async:

```swift
let finalize = { [weak self] in
    guard let self else { return }
    Task { @MainActor in
        // Move ALL of the existing finalize body here (it was already implicitly on main)
        // Insert the diarization await block before rawTranscript is built
    }
}
```

Check the current structure carefully and make the minimal change to introduce one `Task { @MainActor in ... }` wrapper that preserves existing behavior.

- [ ] **Step 6: Build both targets**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3
```

Both must `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Memgram/Audio/RecordingSession.swift
git commit -m "feat: wire SpeakerDiarizer into RecordingSession — dual-channel speaker labelling"
```

---

### Task 7: Final build verification

- [ ] **Step 1: Build macOS Release**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Release build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Build iOS Release**

```bash
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Release build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

---

## Self-Review

**1. Spec coverage:**
- ✅ Channel selection (suppress echo in transcription) — Tasks 1–3
- ✅ Dual-channel diarization (Room 1/2, Remote 1/2) — Task 5
- ✅ Echo suppression via temporal overlap (mic during high sys energy → attribute to remote) — Task 5 (`resolve()`)
- ✅ DB segment speaker label update — Task 4 + Task 6
- ✅ rawTranscript rebuilt with correct labels before summary — Task 6

**2. Placeholder scan:** None. All code blocks are complete with exact types.

**3. Type consistency:**
- `SpeakerDiarizer.runAndResolve(segments:)` takes `[TranscriptSegment]` and returns `[String: String]` (segment UUID string → label). Used in Task 6 with `segment.id.uuidString` as key. ✅
- `MeetingStore.updateSegmentSpeaker(id:speaker:)` takes `String, String`. Called in Task 6 with `segment.id.uuidString`. ✅
- `selectDominantChannel(_:leftEnergy:rightEnergy:threshold:)` is file-scoped (not a method), callable from `WhisperTranscriber` and `ParakeetTranscriber` in the same module. ✅
- `StereoMixer.sampleRate: Double = 16000.0` used in `SpeakerDiarizer` for `sourceSampleRate`. ✅
- `segment.id` is `UUID` on `TranscriptSegment` — `.uuidString` gives the `String` needed to match `MeetingSegment.id` in GRDB. ✅
