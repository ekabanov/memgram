# Memgram — Claude Code Build Plan
### Private, offline-first meeting recorder for macOS
> *Every word, perfectly remembered.*

---

## Project Summary

**Memgram** is a macOS menu bar app that silently captures microphone and system audio during meetings, transcribes locally via whisper.cpp, diarizes speakers using stereo channel routing, generates AI summaries, and provides semantic search across all past meetings. No servers. No bots. No audio stored — transcripts only. LLM backend is user-configurable.

**Bundle ID:** `com.yourname.memgram`
**Minimum macOS:** 13.0 (Ventura)
**Target macOS:** 14.4+ (Sonoma) for full CoreAudio tap path

---

## Design Decisions

| Decision | Choice |
|---|---|
| Platform | macOS first (SwiftUI), iPhone later |
| Storage | Local SQLite only (no cloud for v1) |
| Audio capture | Mic + system audio simultaneously (stereo-routed) |
| System audio primary | CoreAudio ProcessTap (macOS 14.4+) |
| System audio fallback | ScreenCaptureKit (macOS 13.0–14.3) |
| Transcription | whisper.cpp via SwiftWhisper SPM (Metal-accelerated) |
| Diarization | Stereo channel split: mic = Left, system = Right |
| LLM backend | Configurable: Ollama / Claude API / OpenAI API |
| UI | Menu bar app + full window on click |
| Audio retention | Discarded after transcription — transcripts only |
| Note-taking | Fully automatic, silent |
| License | Open source |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│              Menu Bar (SwiftUI)                     │
│   [●] Recording    [Memgram ≡] Open window          │
└──────────────┬──────────────────────────────────────┘
               │
    ┌──────────┴──────────┐
    │                     │
┌───▼────────────┐  ┌─────▼────────────────────────┐
│  Microphone    │  │  SystemAudioCapture          │
│  AVAudioEngine │  │  (protocol, two impls)       │
│  16kHz mono    │  │                              │
│  Left channel  │  │  macOS 14.4+:                │
└───┬────────────┘  │    CoreAudioTapCapture       │
    │               │    AudioHardwareCreateProcess│
    │               │    Tap — no screen perms     │
    │               │                              │
    │               │  macOS 13.0–14.3:            │
    │               │    ScreenCaptureKitCapture   │
    │               │    SCStream, audio-only mode │
    │               │  Right channel               │
    └───────┬────────┴──────────────┘
            │ Stereo 16kHz PCM
            │ L = your mic, R = system audio
    ┌───────▼───────────────────────┐
    │  TranscriptionEngine          │
    │  whisper.cpp (SwiftWhisper)   │
    │  --diarize, stereo input      │
    │  Metal-accelerated, M-series  │
    │  Model: medium.en default     │
    └───────┬───────────────────────┘
            │ [TranscriptSegment] with speaker + channel
    ┌───────▼───────────────────────┐
    │  SQLite (GRDB.swift)          │
    │  meetings, segments,          │
    │  speakers, embeddings         │
    └───────┬───────────────────────┘
            │
    ┌───────▼───────────────────────┐
    │  AI Layer                     │
    │  Ollama / Claude API / OpenAI │
    │  Summary + action items       │
    │  Embeddings for search        │
    └───────┬───────────────────────┘
            │
    ┌───────▼───────────────────────┐
    │  Main Window (SwiftUI)        │
    │  Meeting list, transcript,    │
    │  summary, semantic search     │
    └───────────────────────────────┘
```

---

## Tech Stack

| Component | Technology | Notes |
|---|---|---|
| UI | SwiftUI (macOS 14.0+) | Menu bar + main window |
| Microphone | AVAudioEngine | AVAudioInputNode, 16kHz mono |
| System audio (primary) | CoreAudio ProcessTap | `AudioHardwareCreateProcessTap`, macOS 14.4+, MIT ref: github.com/insidegui/AudioCap |
| System audio (fallback) | ScreenCaptureKit SCStream | `capturesAudio = true`, macOS 13–14.3 |
| Transcription | whisper.cpp via SwiftWhisper SPM | Metal, github.com/exPHAT/SwiftWhisper |
| Diarization | Stereo channel routing + whisper `--diarize` | L=mic, R=system for high-confidence 2-speaker attribution |
| Database | GRDB.swift | SQLite ORM, github.com/groue/GRDB.swift |
| Semantic search | Float32 BLOB embeddings + cosine in Swift | sqlite-vec optional upgrade |
| LLM (local) | Ollama REST API (localhost:11434) | llama3.2, mistral, etc. |
| LLM (cloud) | Claude API / OpenAI API | User provides key, stored in Keychain |
| Package manager | Swift Package Manager | |
| Whisper model | `medium.en` default | ~1.5GB, excellent on M3 Ultra |

---

## Phase 1 — Project Shell & Permissions

**Goal:** Menu bar app that handles permissions gracefully before touching audio.

### 1.1 Xcode project setup
```
- New macOS App, SwiftUI, minimum macOS 13.0
- Bundle ID: com.yourname.memgram
- Entitlements:
    com.apple.security.device.audio-input          (microphone)
    com.apple.security.screen-capture              (SCKit fallback only)
- Info.plist keys:
    NSMicrophoneUsageDescription
      → "Memgram uses your microphone to capture your voice in meetings."
    NSAudioCaptureUsageDescription
      → "Memgram captures system audio to transcribe meeting calls."
    NSScreenCaptureUsageDescription
      → "Memgram captures system audio from your screen to transcribe calls.
         (Used on older macOS only. No video is ever recorded or stored.)"
- SPM dependencies:
    GRDB.swift         https://github.com/groue/GRDB.swift            from: "6.0.0"
    SwiftWhisper       https://github.com/exPHAT/SwiftWhisper          branch: "master"
```

### 1.2 Menu bar shell
```swift
// MemgramApp.swift
@main struct MemgramApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView() }
    }
}

// AppDelegate.swift
// NSStatusItem with NSPopover
// Menu bar icon states:
//   - idle:        gray mic icon (SF Symbol: mic)
//   - recording:   red pulsing dot (mic.fill, red, 1s pulse animation)
//   - processing:  spinner (hourglass)
// Click → show PopoverView
// Long click → open MainWindow
```

### 1.3 Permissions flow
```swift
// PermissionsManager.swift
// Step 1: Request microphone (AVCaptureDevice.requestAccess)
//         → familiar, non-scary, always first
// Step 2 (after mic granted): Request system audio
//         if macOS 14.4+: NSAudioCaptureUsageDescription via CoreAudio tap
//         else: NSScreenCaptureUsageDescription via SCShareableContent.getExcludingDesktopWindows
// Never request both simultaneously
// Show friendly onboarding UI explaining why each is needed
// Store permission state in UserDefaults; re-check on each launch
```

**Deliverable:** App launches in menu bar. Walks user through permissions. No audio yet.

---

## Phase 2 — System Audio Capture (The Hard Part)

**Goal:** Reliable system audio capture. This is the most critical and fragile phase.

### 2.1 SystemAudioCaptureProvider protocol
```swift
protocol SystemAudioCaptureProvider: AnyObject {
    func start() async throws
    func stop() async
    // Emits 16kHz mono Float32 PCM buffers, the right channel (system audio)
    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> { get }
}

// Factory function — called at recording start, not at app launch
func makeSystemAudioCapture() -> SystemAudioCaptureProvider {
    if #available(macOS 14.4, *) {
        return CoreAudioTapCapture()
    } else {
        return ScreenCaptureKitCapture()
    }
}
```

### 2.2 CoreAudioTapCapture (primary — macOS 14.4+)
```swift
// Reference: https://github.com/insidegui/AudioCap (MIT license — study this)
// Reference: https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f

@available(macOS 14.4, *)
final class CoreAudioTapCapture: SystemAudioCaptureProvider {

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> { subject.eraseToAnyPublisher() }

    func start() async throws {
        // STEP 1: Create system-wide tap description
        // isMutexExclusive = false  ← CRITICAL: spy tap, audio still plays through speakers
        // isMixdown = true          ← mix all processes into one stereo stream
        let tapDesc = CATapDescription(processesObjectIDArray: [kAudioObjectSystemObject])
        tapDesc.isMutexExclusive = false
        tapDesc.isMixdown = true
        
        // STEP 2: Create process tap
        var tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapObjectID)
        guard tapStatus == noErr else { throw AudioCaptureError.tapCreationFailed(tapStatus) }
        
        // STEP 3: Get tap UUID for aggregate device
        let tapUID = tapDesc.uuid.uuidString
        
        // STEP 4: ALWAYS destroy existing aggregate device first (prevents error 1852797029)
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        
        // STEP 5: Create private aggregate device
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MemgramTap",
            kAudioAggregateDeviceUIDKey: "com.memgram.audiotap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,   // won't appear in Audio MIDI Setup
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]
        ]
        var aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        
        // Handle "already exists" gracefully
        if aggStatus == 1852797029 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        }
        guard aggStatus == noErr else { throw AudioCaptureError.aggregateDeviceFailed(aggStatus) }
        
        // STEP 6: Read tap format → create AVAudioFormat
        // STEP 7: AudioDeviceCreateIOProcIDWithBlock → resample to 16kHz → emit to subject
    }
    
    func stop() async {
        // Reverse teardown order is critical:
        if let ioProcID { AudioDeviceStop(aggregateDeviceID, ioProcID) }
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID) }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
    }
}
```

### 2.3 ScreenCaptureKitCapture (fallback — macOS 13.0–14.3)
```swift
final class ScreenCaptureKitCapture: SystemAudioCaptureProvider, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }
        
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // IMPORTANT: Set 1fps minimum — we don't want video, but MUST register .screen output
        // or get constant "stream output NOT found. Dropping frame" console spam
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2  // Smallest possible video surface
        
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        // MUST add BOTH outputs even though we discard screen frames
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try await stream?.startCapture()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }  // Discard .screen frames completely
        // Convert CMSampleBuffer → AVAudioPCMBuffer → resample to 16kHz → emit
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Auto-restart on error (SCKit is known to drop randomly)
        Task { try? await self.start() }
    }
}
```

### 2.4 Microphone capture
```swift
// MicrophoneCapture.swift
// AVAudioEngine + AVAudioInputNode
// installTap(onBus: 0, bufferSize: 4096, format: nil)
// Resample to 16kHz mono Float32
// Emit to publisher (Left channel)
```

### 2.5 Stereo mixer
```swift
// StereoMixer.swift
// Receives: mic publisher (Left) + system audio publisher (Right)
// Combines into interleaved stereo 16kHz Float32 buffer every 30 seconds
// L[i] = mic sample, R[i] = system audio sample
// Handles timing drift between streams (mic and system audio may drift slightly)
// Emits: AVAudioPCMBuffer (stereo, 16kHz, Float32) → TranscriptionEngine
```

**Deliverable:** Stereo PCM chunks saved to temp dir every 30s. Verified with a simple audio level visualizer in the popover.

---

## Phase 3 — Transcription Pipeline

**Goal:** Real-time transcription with speaker attribution from stereo channels.

### 3.1 SwiftWhisper integration
```
SPM: https://github.com/exPHAT/SwiftWhisper (wraps whisper.cpp, Metal included)

Model management:
- First launch: download medium.en (~1.5GB) to 
  ~/Library/Application Support/Memgram/models/ggml-medium.en.bin
- Show download progress in onboarding
- Settings: switch between tiny.en / base.en / small.en / medium.en / large-v3
- Verify SHA256 of downloaded model before use
```

### 3.2 TranscriptionEngine
```swift
// TranscriptionEngine.swift
struct TranscriptSegment {
    let id: UUID
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    var speaker: String        // "You" or "Remote" or "Speaker A/B/C"
    var channel: AudioChannel  // .microphone or .system
}

final class TranscriptionEngine {
    // Receives stereo 16kHz PCM buffer (30s chunks)
    // Runs whisper.cpp with:
    //   params.diarize = true
    //   params.n_threads = ProcessInfo.processInfo.activeProcessorCount
    //   params.audio_ctx = 1500  // 30s context
    // Post-processes output:
    //   - Segments where L channel dominant → speaker = "You"
    //   - Segments where R channel dominant → speaker = "Remote"
    //   - [SPEAKER_00]/[SPEAKER_01] tags from whisper → additional diarization signal
    // Emits via Combine publisher for live UI updates
    
    var segmentPublisher: AnyPublisher<TranscriptSegment, Never>
}
```

### 3.3 Live transcript popover
```swift
// PopoverView.swift
// Status line: "● Recording  00:14:32"
// Scrolling list of TranscriptSegments as they arrive
// Speaker label colored differently: "You" (blue) vs "Remote" (gray)
// Auto-scrolls to bottom
// Small and unobtrusive — max 400pt wide, 300pt tall
```

**Deliverable:** End-to-end working: record → transcribe → see attributed live transcript.

---

## Phase 4 — Storage Layer

**Goal:** All meetings persisted in SQLite via GRDB.

### Schema
```sql
CREATE TABLE meetings (
    id          TEXT PRIMARY KEY,    -- UUID
    title       TEXT NOT NULL,       -- "Memgram — Mar 26, 2026, 14:30"
    started_at  REAL NOT NULL,       -- Unix timestamp
    ended_at    REAL,
    duration_seconds INTEGER,
    status      TEXT DEFAULT 'recording',  -- recording|transcribing|done|error
    summary     TEXT,                -- AI-generated, null until processed
    action_items TEXT,               -- JSON array of strings
    raw_transcript TEXT              -- Full joined transcript text
);

CREATE TABLE segments (
    id          TEXT PRIMARY KEY,
    meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    speaker     TEXT,                -- "You", "Remote", "Speaker A", or custom name
    channel     TEXT,                -- 'microphone' | 'system' | 'unknown'
    start_seconds REAL,
    end_seconds   REAL,
    text        TEXT NOT NULL
);

CREATE TABLE speakers (
    id          TEXT PRIMARY KEY,
    meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    label       TEXT,                -- "You", "Remote", "Speaker A"
    custom_name TEXT                 -- User-assigned: "Jevgeni", "Marek"
);

CREATE TABLE embeddings (
    id          TEXT PRIMARY KEY,
    meeting_id  TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
    chunk_text  TEXT NOT NULL,       -- The text that was embedded
    embedding   BLOB NOT NULL,       -- Float32 array, little-endian
    model       TEXT NOT NULL        -- "nomic-embed-text", "text-embedding-3-small", etc.
);

-- FTS5 virtual table for keyword search
CREATE VIRTUAL TABLE segments_fts USING fts5(
    text, 
    speaker,
    content=segments,
    content_rowid=rowid
);
```

### 4.1 GRDB setup
```swift
// AppDatabase.swift
// Singleton DatabaseQueue at ~/Library/Application Support/Memgram/memgram.db
// Migrations using DatabaseMigrator
// WAL mode for concurrent read/write
```

### 4.2 MeetingStore
```swift
// MeetingStore.swift
// createMeeting() → Meeting
// appendSegment(_ segment: TranscriptSegment, to meetingID: UUID)
// finalizeMeeting(_ id: UUID, summary: String, actionItems: [String])
// fetchAll() → [Meeting] (ordered by started_at DESC)
// fetchMeeting(_ id: UUID) → Meeting?
// fetchSegments(meetingID: UUID) → [Segment]
// deleteMeeting(_ id: UUID)  → cascades to segments, speakers, embeddings
```

**Deliverable:** Full meeting history survives app restarts. Delete works cleanly.

---

## Phase 5 — AI Layer

**Goal:** Auto-summary on meeting end. Semantic search across all meetings.

### 5.1 LLMProvider protocol
```swift
protocol LLMProvider {
    var name: String { get }
    func complete(system: String, user: String) async throws -> String
    func embed(text: String) async throws -> [Float]
}

// OllamaProvider  — POST http://localhost:11434/api/generate (summary)
//                   POST http://localhost:11434/api/embeddings (nomic-embed-text)
// ClaudeProvider  — POST https://api.anthropic.com/v1/messages
//                   Embeddings: delegate to OllamaProvider (Claude has no embedding API)
// OpenAIProvider  — POST https://api.openai.com/v1/chat/completions
//                   POST https://api.openai.com/v1/embeddings (text-embedding-3-small)
```

### 5.2 Settings UI (LLM)
```swift
// SettingsView.swift
// Picker: Local (Ollama) | Claude API | OpenAI API
// API key field → stored in Keychain (never in SQLite or UserDefaults)
// Ollama: fetch model list from localhost:11434/api/tags, show picker
// "Test connection" button → simple completion test
// Warning if Ollama not running: "Start Ollama with 'ollama serve'"
```

### 5.3 SummaryEngine
```swift
// Triggered automatically when: meeting ends + all transcription chunks processed
// System prompt:
//   "You are a concise meeting assistant. Be factual and brief. 
//    Use the speaker labels provided. Format action items as a simple list."
// User prompt:
//   "Transcript of a meeting:\n\n{full_transcript}\n\n
//    Provide:
//    1. A 3-5 sentence summary of what was discussed
//    2. Key decisions made (if any)
//    3. Action items, with owner if attributable from the transcript
//    Respond in plain text, no markdown headers."
// For long meetings (>60min): chunk into 20min sections, summarize each, then summarize summaries
// Save result to meetings.summary + meetings.action_items (JSON)
```

### 5.4 EmbeddingEngine
```swift
// After summary: embed transcript in overlapping 512-token chunks
// Store as Float32 BLOB in embeddings table
// Cosine similarity computed in Swift (dot product of normalized vectors)
```

### 5.5 SearchEngine
```swift
// HybridSearch(query: String) → [SearchResult]
// 
// 1. FTS5 keyword search across segments_fts → ranked by BM25
// 2. Embed query → cosine similarity against all stored embeddings
// 3. Merge results: FTS5 score * 0.4 + semantic score * 0.6
// 4. Return top 20 results with: meeting title, timestamp, speaker, snippet
// 
// SearchResult { meetingID, segmentID, speaker, snippet, timestamp, score }
```

**Deliverable:** Every meeting auto-summarized within ~30s of ending. Search returns relevant results across full history.

---

## Phase 6 — Main Window UI

**Goal:** Full-featured meeting browser opened from menu bar.

### Layout
```
┌────────────────────────────────────────────────────────────────┐
│  🔴 Memgram                [🔍 Search meetings...]   [● Rec]   │
├────────────────┬───────────────────────────────────────────────┤
│                │                                               │
│  Mar 26        │  Meeting — Mar 26, 2026  14:30  (1h 12m)     │
│  ● 14:30  1h12 │  ──────────────────────────────────────────  │
│    10:00  45m  │                                               │
│                │  SUMMARY                                      │
│  Mar 25        │  Discussed Q2 roadmap and infrastructure      │
│    16:00  30m  │  migration. Three decisions made on vendor    │
│    11:30  1h   │  selection. Two action items assigned.        │
│                │                                               │
│  Mar 24        │  ACTION ITEMS                                 │
│    09:00  2h   │  □  Review vendor proposal — Jevgeni (Fri)   │
│                │  □  Update architecture diagram — Remote      │
│                │                                               │
│                │  TRANSCRIPT                          [Rename] │
│                │  ┌──────────────────────────────────────────┐ │
│                │  │ You  ·  14:32:04                         │ │
│                │  │ "Let's start with the infra migration..." │ │
│                │  │                                          │ │
│                │  │ Remote  ·  14:32:18                      │ │
│                │  │ "The main blocker is the Kubernetes..."  │ │
│                │  └──────────────────────────────────────────┘ │
└────────────────┴───────────────────────────────────────────────┘
```

### 6.1 MeetingListView
- Grouped by date (today, yesterday, this week, earlier)
- Status indicator: recording (red dot), transcribing (spinner), done (checkmark)
- Duration label, truncated title
- Swipe-to-delete with confirmation

### 6.2 MeetingDetailView
- Summary + action items panel (top)
- Full scrollable transcript (bottom)
- Speaker labels as colored chips (clickable to rename)
- Jump-to-timestamp: click any segment → shows exact time
- Copy transcript button

### 6.3 SpeakerRenameView
```
Click "You" or "Remote" → inline popover
Text field: "Rename 'Remote' to..."
"Apply to this meeting" vs "Remember for future meetings"
Propagates rename to all segments in meeting
```

### 6.4 SearchView
```
Global search bar (Cmd+F from main window)
Results list: meeting title + date + speaker + snippet + timestamp
Click result → opens that meeting, scrolls to that segment, highlights text
Empty state: "No results for '{query}'"
```

**Deliverable:** Fully navigable meeting history with working search and speaker renaming.

---

## Phase 7 — Polish & Edge Cases

### 7.1 Whisper model download wizard
```
First launch (after permissions):
  "Memgram needs a transcription model to work."
  "Download medium.en (~1.5 GB) — recommended for best accuracy"
  "Download tiny.en (~75 MB) — faster, lower accuracy"
  [Download] button → URLSession download with progress bar
  SHA256 verification on completion
  Retry on failure (resume-capable)
```

### 7.2 Recording safeguards
```swift
// SessionGuard.swift
// Prevent double-start: check RecordingSession.isActive before starting
// System sleep mid-recording:
//   NSWorkspace.shared.notificationCenter → willSleepNotification → pause
//   didWakeNotification → resume (re-init audio engine)
// Low disk space:
//   Check available space before recording
//   Warn at < 500MB (transcripts are tiny but whisper models need temp space)
// Crash recovery:
//   On launch: scan for meetings with status = 'recording'
//   Offer: "A recording was interrupted. Transcribe what was captured?" or "Discard"
```

### 7.3 Auto-title meetings
```swift
// Default: "Meeting — {weekday}, {month} {day}, {year}  {HH:MM}"
// After transcription: attempt to extract topic from first 2 minutes of transcript
//   Prompt: "In 4 words or fewer, what is this meeting about? Transcript: {first_segment_texts}"
//   If result is sensible, offer as suggested title (user can accept or keep default)
// User can rename by clicking title in detail view
```

### 7.4 Privacy indicators
```swift
// Menu bar icon is clearly red and animated while recording
// Optional: "Memgram started recording" notification on start
// Settings toggle: show/hide notification
// About page: explicit statement "Audio is never stored. Transcripts only."
```

### 7.5 CoreAudio tap resilience
```swift
// Wrap all CoreAudio calls in retry logic with exponential backoff
// On error 1852797029: destroy and recreate aggregate device (up to 3 attempts)
// On unexpected tap termination: log + attempt restart + notify user if repeated
// On ScreenCaptureKit fallback: auto-restart stream in didStopWithError delegate
```

---

## File Structure

```
Memgram/
├── MemgramApp.swift
├── AppDelegate.swift               # NSStatusItem, popover, window management
│
├── Audio/
│   ├── MicrophoneCapture.swift     # AVAudioEngine, 16kHz mono
│   ├── SystemAudioCaptureProvider.swift  # Protocol + factory
│   ├── CoreAudioTapCapture.swift   # Primary (macOS 14.4+)
│   ├── ScreenCaptureKitCapture.swift     # Fallback (macOS 13–14.3)
│   ├── StereoMixer.swift           # Combines L+R into 30s stereo chunks
│   └── RecordingSession.swift      # Session lifecycle management
│
├── Transcription/
│   ├── TranscriptionEngine.swift   # whisper.cpp via SwiftWhisper
│   ├── DiarizationParser.swift     # Channel-based + whisper tag parsing
│   └── WhisperModelManager.swift   # Download, verify, switch models
│
├── Storage/
│   ├── AppDatabase.swift           # GRDB DatabaseQueue singleton
│   ├── MeetingStore.swift          # CRUD operations
│   ├── Migrations.swift            # Versioned schema migrations
│   └── Models/
│       ├── Meeting.swift
│       ├── Segment.swift
│       ├── Speaker.swift
│       └── Embedding.swift
│
├── AI/
│   ├── LLMProvider.swift           # Protocol
│   ├── OllamaProvider.swift        # localhost:11434
│   ├── ClaudeProvider.swift        # api.anthropic.com
│   ├── OpenAIProvider.swift        # api.openai.com
│   ├── SummaryEngine.swift         # Post-meeting summarization
│   └── EmbeddingEngine.swift       # Chunk + embed transcripts
│
├── Search/
│   └── SearchEngine.swift          # Hybrid FTS5 + semantic
│
├── UI/
│   ├── MenuBar/
│   │   ├── PopoverView.swift
│   │   └── LiveTranscriptView.swift
│   ├── MainWindow/
│   │   ├── MainWindowView.swift
│   │   ├── MeetingListView.swift
│   │   ├── MeetingDetailView.swift
│   │   ├── SpeakerRenameView.swift
│   │   └── SearchView.swift
│   └── Settings/
│       ├── SettingsView.swift
│       └── PermissionsView.swift
│
├── Utilities/
│   ├── SessionGuard.swift          # Sleep/wake, crash recovery, disk space
│   ├── KeychainHelper.swift        # API key storage
│   └── AudioConverter.swift        # Resample to 16kHz Float32
│
└── Resources/
    ├── Memgram.entitlements
    └── Assets.xcassets             # App icon (stylized M with audio waveform)
```

---

## SPM Dependencies

```swift
.package(url: "https://github.com/groue/GRDB.swift",     from: "6.0.0"),
.package(url: "https://github.com/exPHAT/SwiftWhisper",  branch: "master"),
```

---

## Reference Repositories to Study Before Building

These are real, working open-source implementations to read before writing audio code:

| Repo | What to learn |
|---|---|
| `github.com/insidegui/AudioCap` | CoreAudio ProcessTap setup, full working Swift implementation |
| `gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f` | Minimal C CoreAudio tap example, good for understanding raw API flow |
| `github.com/Mnpn/Azayaka` | Menu bar app + ScreenCaptureKit audio, fallback path patterns |
| `github.com/lihaoyun6/QuickRecorder` | Production quality, handles both paths, complex session management |

---

## Build Order for Claude Code Sessions

Each session prompt is self-contained. Paste verbatim.

---

### Session 1
```
Build a macOS SwiftUI menu bar app called Memgram (bundle ID: com.memgram.app).

Requirements:
- NSStatusItem in menu bar with three icon states: idle (gray mic SF Symbol), 
  recording (red pulsing mic.fill), processing (hourglass)
- Click opens NSPopover with a placeholder "Not recording" label
- A PermissionsManager that requests microphone permission (AVCaptureDevice), 
  then on success requests system audio permission using NSAudioCaptureUsageDescription
  (CoreAudio tap path for macOS 14.4+) or NSScreenCaptureUsageDescription (SCKit fallback)
- Never request both permissions simultaneously
- Show a simple onboarding sheet on first launch explaining what each permission is for
- Info.plist keys: NSMicrophoneUsageDescription, NSAudioCaptureUsageDescription, 
  NSScreenCaptureUsageDescription
- Entitlements: audio-input, screen-capture
- SPM dependencies: GRDB.swift (6.0.0+)
- Minimum macOS 13.0, deploy target 14.0
```

---

### Session 2
```
Add system audio capture to Memgram using a dual-path architecture.

Requirements:
- SystemAudioCaptureProvider protocol with start(), stop(), and a Combine publisher 
  emitting AVAudioPCMBuffer (16kHz mono Float32)
- CoreAudioTapCapture implementation (macOS 14.4+):
  - Use AudioHardwareCreateProcessTap with CATapDescription targeting kAudioObjectSystemObject
  - isMutexExclusive = false (spy tap — audio still plays through speakers)
  - isMixdown = true
  - Create private aggregate device (kAudioAggregateDeviceIsPrivateKey = true)
  - Always destroy aggregate device before creating to prevent OSStatus 1852797029
  - Teardown in reverse order: stop IOProc → destroy IOProc → destroy aggregate → destroy tap
  - Reference implementation: https://github.com/insidegui/AudioCap
- ScreenCaptureKitCapture fallback (macOS 13.0–14.3):
  - SCStream with capturesAudio = true, minimumFrameInterval = CMTime(1,1), 2x2 video
  - MUST register both .screen and .audio stream outputs (even though .screen frames are discarded)
  - Auto-restart on didStopWithError
- MicrophoneCapture: AVAudioEngine tap, resampled to 16kHz mono Float32
- StereoMixer: combines mic (Left channel) + system audio (Right channel) into 
  stereo 16kHz Float32 buffers every 30 seconds
- Factory function makeSystemAudioCapture() → CoreAudioTapCapture on 14.4+, else ScreenCaptureKitCapture
- Save 30s PCM chunks to /tmp/memgram/ during recording (cleared on stop)
- Show real-time audio level meter in the popover for both channels
```

---

### Session 3
```
Add whisper.cpp transcription to Memgram via SwiftWhisper SPM package.

Requirements:
- Add SwiftWhisper SPM dependency: https://github.com/exPHAT/SwiftWhisper (branch: master)
- WhisperModelManager: 
  - Download medium.en model to ~/Library/Application Support/Memgram/models/
  - Show download progress in a first-launch sheet
  - SHA256 verification after download
  - Support switching between tiny.en / base.en / small.en / medium.en
- TranscriptionEngine:
  - Input: stereo 16kHz Float32 PCM buffers from StereoMixer
  - whisper params: diarize=true, n_threads=ProcessInfo.activeProcessorCount, audio_ctx=1500
  - Post-process: segments where left channel dominant → speaker="You", 
    right channel dominant → speaker="Remote"
  - Also parse [SPEAKER_00]/[SPEAKER_01] whisper diarization tags as secondary signal
  - Output: [TranscriptSegment] via Combine publisher
- TranscriptSegment: { id, startSeconds, endSeconds, text, speaker, channel }
- LiveTranscriptView in popover: scrolling list of segments, 
  "You" in blue, "Remote" in gray, auto-scrolls to bottom
- RecordingSession: manages start/stop, coordinates all audio components
```

---

### Session 4
```
Add SQLite persistence to Memgram using GRDB.swift.

Schema (implement exactly):
- meetings: id (UUID PK), title, started_at, ended_at, duration_seconds, 
  status (recording|transcribing|done|error), summary, action_items (JSON), raw_transcript
- segments: id, meeting_id (FK → meetings CASCADE), speaker, channel, 
  start_seconds, end_seconds, text
- speakers: id, meeting_id (FK), label, custom_name
- embeddings: id, meeting_id (FK), chunk_text, embedding (BLOB Float32), model
- FTS5 virtual table on segments (text, speaker, content=segments)

Requirements:
- AppDatabase singleton at ~/Library/Application Support/Memgram/memgram.db, WAL mode
- DatabaseMigrator for versioned migrations
- MeetingStore with: createMeeting, appendSegment, finalizeMeeting, fetchAll, 
  fetchMeeting, fetchSegments, deleteMeeting (cascade)
- Wire TranscriptionEngine → MeetingStore: segments saved in real-time as they arrive
- Meeting status transitions: recording → transcribing → done
- On app launch: detect any meetings with status='recording', offer recovery or discard
```

---

### Session 5
```
Add LLM-powered summaries and semantic search to Memgram.

Requirements:
- LLMProvider protocol: name, complete(system:user:) async throws → String, 
  embed(text:) async throws → [Float]
- OllamaProvider: POST localhost:11434/api/generate (llama3.2 default), 
  POST localhost:11434/api/embeddings (nomic-embed-text)
- ClaudeProvider: POST api.anthropic.com/v1/messages (claude-sonnet-4-6 model),
  embed() delegates to OllamaProvider (Claude has no embedding API)
- OpenAIProvider: POST api.openai.com/v1/chat/completions, 
  POST api.openai.com/v1/embeddings (text-embedding-3-small)
- API keys stored in Keychain (never UserDefaults or SQLite)
- SummaryEngine: triggered when meeting status → 'done'
  System: "You are a concise meeting assistant. Be factual. Use speaker labels."
  User: "Transcript:\n\n{transcript}\n\nProvide: 1) 3-5 sentence summary 
         2) Key decisions 3) Action items with owner. Plain text, no markdown."
  For meetings >60min: summarize in 20min chunks then summarize summaries
- EmbeddingEngine: embed transcript in overlapping 512-token chunks → store in embeddings table
- SearchEngine: HybridSearch combining FTS5 (BM25 score * 0.4) + cosine similarity (0.6)
  Cosine computed in Swift on Float32 BLOB arrays
  Returns [SearchResult] { meetingID, speaker, snippet, timestampSeconds, score }
- SettingsView: picker for LLM backend, API key field, Ollama model picker 
  (fetched from localhost:11434/api/tags), test connection button
```

---

### Session 6
```
Build the Memgram main window UI.

Requirements:
- Open from menu bar via dedicated button or double-click
- Three-column layout: meeting list sidebar, detail pane
- MeetingListView:
  - Grouped by date (Today, Yesterday, This Week, Earlier)
  - Each row: colored status dot, title, duration
  - Swipe-to-delete with "Delete Recording?" confirmation
- MeetingDetailView:
  - Header: title (editable on click), date, duration
  - Summary section: 3-5 sentence summary text
  - Action items section: checkbox list (checked = done, stored in UserDefaults per meeting)
  - Transcript section: scrollable list of TranscriptSegments
    Each segment: speaker chip (colored, clickable), timestamp, text
    Click timestamp → copies "Meeting — Mar 26 14:32:04" to clipboard
- SpeakerRenameView: popover on speaker chip click
  Text field to rename, "Apply to this meeting" vs "Remember for all meetings" toggle
  Renames propagate to all segments in meeting (or all meetings if global)
- SearchView: activated by Cmd+F or search bar
  Full-height results list, each result shows meeting title + date + speaker + snippet
  Click → opens meeting, scrolls to segment, highlights matching text
- Empty states: "No meetings yet — start recording from the menu bar"
```

---

### Session 7
```
Add production polish and resilience to Memgram.

Requirements:
- WhisperModelManager: first-launch wizard with model download, 
  progress bar, SHA256 verification, retry on failure
- SessionGuard:
  - NSWorkspace willSleepNotification → pause recording gracefully
  - didWakeNotification → resume (reinitialize audio engine)
  - Check available disk space before recording, warn at < 500MB
  - On launch: detect interrupted recordings (status='recording'), 
    show recovery sheet: "Transcribe what was captured?" or "Discard"
- Auto-title: after transcription, prompt LLM with first 2 min of transcript for 
  "4-word topic" suggestion, show as editable suggestion to user
- CoreAudio tap resilience:
  - Retry up to 3 times with 500ms backoff on error 1852797029
  - Log all CoreAudio errors with OSStatus codes to ~/Library/Logs/Memgram/
- Privacy: menu bar icon always clearly red + animated during recording
  Optional "Memgram started recording" notification (toggle in Settings)
- About panel: explicit privacy statement, link to GitHub
- All text copyable via right-click context menu throughout the app
```

---

## Risk Register

| Risk | Mitigation |
|---|---|
| CoreAudio tap error 1852797029 (aggregate exists) | Always destroy-before-create; retry 3x with 500ms backoff |
| SCKit fallback crashes after ~4min (known macOS 14.x bug) | Auto-restart in didStopWithError; log for user |
| Sequoia re-prompts "bypass window picker" every few weeks | Use CoreAudio tap path (macOS 14.4+) which avoids this entirely |
| Ollama not running when user tries summary | Detect on settings open, show "Start Ollama: 'ollama serve'" |
| Long meetings (2h+) exceed LLM context window | Chunked summarization: 20min sections → final summary of summaries |
| App notarization may reject AudioCaptureUsageDescription | Test with a real Developer ID certificate early; have SCKit fallback ready |
| whisper.cpp model download fails mid-way | SHA256 check + resume-capable URLSession download |
| isMutexExclusive accidentally true → mutes speakers | Integration test: verify system audio plays during recording |

---

## v2 Roadmap

- iCloud sync via CloudKit
- Calendar integration (auto-start on meeting detection)  
- iPhone companion app (same whisper.cpp, smaller model)
- Cross-meeting memory: "what did we decide about X last month?"
- pyannote.audio for 3+ speaker diarization
- MCP server: expose Memgram context to Claude/ChatGPT
- Export: share transcript as PDF or markdown
