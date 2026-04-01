# Speaker Enrollment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user enroll their voice during onboarding so Sortformer can label their speech with their real name in diarized meeting summaries.

**Architecture:** A new `SpeakerEnrollmentStore` persists the user's name and 5-second raw audio enrollment sample to disk. OnboardingView gains an `enrollVoice` step between systemAudio and done, pre-filling the name from `NSFullUserName()` and recording via `MicrophoneCapture`. `SpeakerDiarizer.runAndResolve` enrolls the stored speaker on both diarizer instances before `processComplete`. `speakerLabel(in:atSec:prefix:)` uses `speaker.name` when the diarizer assigned one. RecordingSettingsTab gets a "Your Voice" section for updates.

**Tech Stack:** Swift, FluidAudio `SortformerDiarizer.enrollSpeaker`, `AVAudioEngine` / `MicrophoneCapture`, UserDefaults + FileManager for persistence, macOS 14+ (enrollment step macOS-only)

---

## File Structure

**New files:**
- `Memgram/Transcription/SpeakerEnrollmentStore.swift` — persists `(name: String, samples: [Float])` to Application Support

**Modified files:**
- `Memgram/UI/MenuBar/OnboardingView.swift` — add `enrollVoice` step (5th step, between systemAudio and done)
- `Memgram/UI/Settings/SettingsView.swift` — add "Your Voice" section to `RecordingSettingsTab`
- `Memgram/Transcription/SpeakerDiarizer.swift` — enroll stored speaker before `processComplete`, use `speaker.name` in label lookup
- `Memgram/UI/MainWindow/MeetingDetailView.swift` — no change needed (summary already uses resolved names)

---

### Task 1: SpeakerEnrollmentStore

**Files:**
- Create: `Memgram/Transcription/SpeakerEnrollmentStore.swift`

Stores the user's display name and raw 16 kHz mono Float32 enrollment audio (≈5 s = 80 000 samples = 320 KB) as a binary file. Loading is synchronous — it's just a file read.

- [ ] **Step 1: Create SpeakerEnrollmentStore.swift**

```swift
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
git add Memgram/Transcription/SpeakerEnrollmentStore.swift Memgram.xcodeproj
git commit -m "feat: add SpeakerEnrollmentStore — persist user name and voice sample"
```

---

### Task 2: Add enrollVoice step to OnboardingView

**Files:**
- Modify: `Memgram/UI/MenuBar/OnboardingView.swift`

Add a 5th onboarding step between `systemAudio` and `done`. The step:
- Pre-fills the name field with `NSFullUserName()`
- Shows a hold-to-record button: user holds for 5 seconds, progress bar fills
- On release (or after 5 s): saves audio + name via `SpeakerEnrollmentStore`
- Has a "Skip" button to bypass enrollment (name stays empty, labels fall back to Speaker A/B)

The recording uses `AVAudioEngine` directly (not `MicrophoneCapture`, which is heavy and starts a full session). We need 16 kHz mono PCM — same as MicrophoneCapture's format.

- [ ] **Step 1: Add the enrollVoice case and update OnboardingView**

Read `Memgram/UI/MenuBar/OnboardingView.swift` first to see current structure, then apply these changes:

**1a. Add `enrollVoice` to the step enum and update all switch statements:**

```swift
enum OnboardingStep {
    case welcome
    case microphone
    case systemAudio
    case enrollVoice   // NEW
    case done
}
```

**1b. Update `stepContent` to handle the new case:**

```swift
case .enrollVoice:
    EnrollVoiceStepView(onComplete: {
        step = .done
    }, onSkip: {
        step = .done
    })
```

**1c. Update `currentStepIndex`:**

```swift
private var currentStepIndex: Int {
    switch step {
    case .welcome:      return 0
    case .microphone:   return 1
    case .systemAudio:  return 2
    case .enrollVoice:  return 3
    case .done:         return 4
    }
}
```

**1d. Update step indicator dot count from 4 to 5:**

```swift
ForEach(0..<5) { i in
```

**1e. Update `nextButtonTitle`:**

```swift
case .enrollVoice: return "Done"
```

**1f. Update `goNext()` — after systemAudio, go to enrollVoice:**

```swift
case .systemAudio:
    Task {
        _ = await permissions.requestSystemAudioPermission()
        await MainActor.run { step = .enrollVoice }
    }
case .enrollVoice:
    permissions.markOnboardingComplete()
```

**1g. Update `goBack()`:**

```swift
case .enrollVoice: step = .systemAudio
case .done:        step = .enrollVoice
```

**Note:** The `EnrollVoiceStepView` handles its own "Complete" / "Skip" actions via closures — the navigation bar "Done" button on that step is hidden (the view controls its own flow). Simplest approach: hide the navigation bar buttons when on `.enrollVoice` by making `navigationButtons` return an empty view for that step.

Add to `navigationButtons`:

```swift
private var navigationButtons: some View {
    Group {
        if step == .enrollVoice {
            EmptyView()   // EnrollVoiceStepView has its own Continue/Skip buttons
        } else {
            HStack(spacing: 8) {
                if step != .welcome {
                    Button("Back") { goBack() }
                        .buttonStyle(.plain)
                }
                Button(nextButtonTitle) { goNext() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
```

- [ ] **Step 2: Add EnrollVoiceStepView at the end of the file**

```swift
// MARK: - Enroll Voice Step

struct EnrollVoiceStepView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var name: String = NSFullUserName()
    @State private var isRecording = false
    @State private var progress: Double = 0
    @State private var recorded = false
    @State private var samples: [Float] = []

    private let targetDuration: Double = 5.0
    private let sampleRate: Double = 16_000
    private var targetSamples: Int { Int(sampleRate * targetDuration) }

    // AVAudioEngine for enrollment recording
    @State private var engine: AVAudioEngine? = nil
    @State private var timer: Timer? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: recorded ? "person.fill.checkmark" : "waveform.circle")
                .font(.system(size: 44))
                .foregroundColor(recorded ? .green : .accentColor)
                .animation(.easeInOut, value: recorded)

            VStack(spacing: 8) {
                Text("Identify Your Voice")
                    .font(.title3.bold())
                Text("Memgram uses your voice to label who's speaking in meeting transcripts.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Name field
            HStack {
                Text("Your name:")
                    .foregroundColor(.secondary)
                TextField("Full name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            if recorded {
                Label("Voice sample saved", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.callout)
            } else {
                // Record button
                VStack(spacing: 6) {
                    Button(action: toggleRecording) {
                        ZStack {
                            Circle()
                                .fill(isRecording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.12))
                                .frame(width: 60, height: 60)
                            if isRecording {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "mic.fill")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isRecording ? "Recording…" : "Click to record 5 seconds of your voice")

                    if isRecording {
                        ProgressView(value: progress)
                            .frame(width: 140)
                            .tint(.red)
                        Text("Recording… \(Int(progress * targetDuration))s / 5s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Click mic to record 5 seconds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    stopRecording()
                    onSkip()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                if recorded {
                    Button("Continue") {
                        SpeakerEnrollmentStore.shared.enrolledName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !samples.isEmpty {
                            SpeakerEnrollmentStore.shared.saveAudio(samples)
                        }
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        samples = []
        progress = 0
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buf, _ in
            let frameCapacity = AVAudioFrameCount(
                Double(buf.frameLength) * (sampleRate / buf.format.sampleRate)) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            var consumed = false
            try? converter.convert(to: out, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buf
            }
            if let ptr = out.floatChannelData?[0] {
                let arr = Array(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))
                DispatchQueue.main.async {
                    self.samples.append(contentsOf: arr)
                    self.progress = min(1.0, Double(self.samples.count) / Double(self.targetSamples))
                    if self.samples.count >= self.targetSamples { self.finishRecording() }
                }
            }
        }
        try? eng.start()
        engine = eng
        isRecording = true
    }

    private func stopRecording() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
    }

    private func finishRecording() {
        stopRecording()
        if samples.count > targetSamples { samples = Array(samples.prefix(targetSamples)) }
        recorded = true
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/UI/MenuBar/OnboardingView.swift
git commit -m "feat: add enrollVoice onboarding step with 5s mic recording and system name pre-fill"
```

---

### Task 3: Add "Your Voice" section to RecordingSettingsTab

**Files:**
- Modify: `Memgram/UI/Settings/SettingsView.swift`

Adds a section to `RecordingSettingsTab` showing enrollment status and a button to update.

- [ ] **Step 1: Read current RecordingSettingsTab in SettingsView.swift**

- [ ] **Step 2: Add @State for the re-record sheet and enrollment store observation**

At the top of `RecordingSettingsTab`, add:

```swift
struct RecordingSettingsTab: View {
    @ObservedObject private var backendManager = TranscriptionBackendManager.shared
    @ObservedObject private var whisperManager = WhisperModelManager.shared
    @State private var showEnrollSheet = false
    @State private var enrollmentVersion = 0  // bump to refresh status display
```

- [ ] **Step 3: Add "Your Voice" section to the Form**

Add after the existing "Whisper Model" section:

```swift
Section("Your Voice") {
    if SpeakerEnrollmentStore.shared.hasEnrollment {
        LabeledContent("Enrolled as") {
            Text(SpeakerEnrollmentStore.shared.enrolledName ?? "Unknown")
                .foregroundStyle(.secondary)
        }
        HStack {
            Button("Update Voice Sample") { showEnrollSheet = true }
            Spacer()
            Button("Remove", role: .destructive) {
                SpeakerEnrollmentStore.shared.clear()
                enrollmentVersion += 1
            }
        }
    } else {
        Text("No voice enrolled. Speakers will be labelled Speaker A, B, etc.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Enroll Your Voice") { showEnrollSheet = true }
            .buttonStyle(.bordered)
    }
}
.sheet(isPresented: $showEnrollSheet) {
    VoiceEnrollmentSheet(onDone: {
        showEnrollSheet = false
        enrollmentVersion += 1
    })
}
```

- [ ] **Step 4: Add VoiceEnrollmentSheet below RecordingSettingsTab**

```swift
// MARK: - Voice Enrollment Sheet

private struct VoiceEnrollmentSheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            EnrollVoiceStepView(
                onComplete: onDone,
                onSkip: onDone
            )
            .navigationTitle("Enroll Your Voice")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(width: 480, height: 340)
    }
}
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -20
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Memgram/UI/Settings/SettingsView.swift
git commit -m "feat: add Your Voice section to Recording settings — enroll/update/remove"
```

---

### Task 4: Wire enrollment into SpeakerDiarizer

**Files:**
- Modify: `Memgram/Transcription/SpeakerDiarizer.swift`

Two changes:
1. In `runAndResolve`: before calling `processComplete`, enroll the stored speaker on both diarizer instances
2. In `speakerLabel(in:atSec:prefix:)`: use `speaker.name` when set by the diarizer

- [ ] **Step 1: Read the runAndResolve and speakerLabel methods in SpeakerDiarizer.swift**

- [ ] **Step 2: Add enrollment before processComplete calls**

Find the block that creates `micDiarizer` and `sysDiarizer` in `runAndResolve`. After `micDiarizer.initialize(models: loadedModels)` and `sysDiarizer.initialize(models: loadedModels)`, add:

```swift
// Enroll the stored user speaker on both diarizer instances
if let enrolledName = SpeakerEnrollmentStore.shared.enrolledName,
   let enrollAudio = SpeakerEnrollmentStore.shared.loadAudio() {
    log.info("Enrolling '\(enrolledName)' speaker (\(enrollAudio.count) samples) on both channels")
    let _ = try? micDiarizer.enrollSpeaker(withAudio: enrollAudio,
                                           sourceSampleRate: sampleRate,
                                           named: enrolledName)
    let _ = try? sysDiarizer.enrollSpeaker(withAudio: enrollAudio,
                                           sourceSampleRate: sampleRate,
                                           named: enrolledName)
} else {
    log.debug("No speaker enrollment found — labels will be Speaker A/B/C")
}
```

Then update both `processComplete` calls to keep the enrolled speaker:

```swift
micTimeline = try await Task.detached(priority: .userInitiated) {
    try micDiarizer.processComplete(micInput,
                                    sourceSampleRate: StereoMixer.sampleRate,
                                    keepingEnrolledSpeakers: true)
}.value
```

```swift
sysTimeline = try await Task.detached(priority: .userInitiated) {
    try sysDiarizer.processComplete(sysInput,
                                    sourceSampleRate: StereoMixer.sampleRate,
                                    keepingEnrolledSpeakers: true)
}.value
```

- [ ] **Step 3: Update speakerLabel to use speaker.name when set**

Find `speakerLabel(in:atSec:prefix:)`. When a speaker has a `name` set (by enrollment), use it directly instead of generating "Room 1" etc.:

```swift
private func speakerLabel(in timeline: DiarizerTimeline, atSec: Double, prefix: String) -> String {
    let t = Float(atSec)
    for (_, speaker) in timeline.speakers {
        let allSegments = speaker.finalizedSegments + speaker.tentativeSegments
        for seg in allSegments where seg.startTime <= t && t <= seg.endTime {
            // Use the enrolled name if the diarizer assigned one; otherwise fall back to index
            if let name = speaker.name, !name.isEmpty {
                return name
            }
            return "\(prefix) \(speaker.index + 1)"
        }
    }
    return prefix
}
```

- [ ] **Step 4: Update normaliseSpeakerLabels in SummaryEngine to pass through real names**

In `SummaryEngine.normaliseSpeakerLabels`, enrolled names like "Jevgeni" should NOT be replaced with "Speaker A" — only the generic Room/Remote/You/Remote labels should be anonymised. Update the regex pattern to exclude labels that don't match the diarizer patterns:

The current regex `#"^(Room \d+|Remote \d+|You|Remote)(?=:)"#` already only matches known diarizer labels. Any speaker named "Jevgeni" by enrollment will have lines like `Jevgeni: text` which the regex won't touch — they pass through unchanged. No code change needed here.

However, the header should mention any real names found so the LLM knows those are already resolved:

No change needed — if "Jevgeni" appears as a speaker label and isn't in the regex, it passes through as-is and the LLM sees it correctly.

- [ ] **Step 5: Build both targets**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project Memgram.xcodeproj -scheme MemgramMobile -configuration Debug build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -destination 'generic/platform=iOS Simulator' 2>&1 | tail -3
```

Expected: both `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Memgram/Transcription/SpeakerDiarizer.swift
git commit -m "feat: enroll stored user speaker in Sortformer before diarization — real names in summaries"
```

---

### Task 5: Final build verification

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
- ✅ Pull name from system (`NSFullUserName()`) — Task 2 pre-fills the name field
- ✅ Onboarding step — Task 2 adds `enrollVoice` between systemAudio and done
- ✅ Settings section for updates — Task 3 adds "Your Voice" section with update/remove
- ✅ Enrollment used in diarization — Task 4 calls `enrollSpeaker` before `processComplete`
- ✅ Real name in summary — Task 4 `speakerLabel` uses `speaker.name`; `normaliseSpeakerLabels` passes enrolled names through unchanged

**2. Placeholder scan:** No TBDs. All code blocks are complete.

**3. Type consistency:**
- `SpeakerEnrollmentStore.shared.loadAudio()` returns `[Float]?` — used as `enrollAudio: [Float]` in Task 4 ✅
- `SpeakerEnrollmentStore.shared.enrolledName` is `String?` — guarded with `if let` in Task 4 ✅
- `EnrollVoiceStepView` has `onComplete: () -> Void` and `onSkip: () -> Void` closures — used in both OnboardingView (Task 2) and VoiceEnrollmentSheet (Task 3) ✅
- `SpeakerEnrollmentStore.shared.saveAudio(_:)` takes `[Float]` — called with `samples: [Float]` in Task 2 ✅
- `enrollSpeaker(withAudio:sourceSampleRate:named:)` takes `[Float]`, `Double?`, `String?` — correct types passed in Task 4 ✅
