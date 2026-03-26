# Session 4: SQLite Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist meetings and transcript segments to SQLite using GRDB.swift, wire the transcription pipeline to save segments in real-time, and offer recovery of interrupted recordings on launch.

**Architecture:** `AppDatabase` owns a WAL-mode `DatabaseQueue` and runs versioned migrations. `MeetingStore` provides all CRUD operations. `RecordingSession` creates a meeting on start, streams segments to the DB, and finalizes the meeting on stop. AppDelegate checks for interrupted meetings on launch and offers recovery via an alert in `PopoverView`.

**Tech Stack:** GRDB.swift 6.x (already in project), SwiftUI, Combine

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Memgram/Database/AppDatabase.swift` | Singleton DatabaseQueue, WAL, migrations |
| Create | `Memgram/Database/Meeting.swift` | Meeting GRDB record + MeetingStatus enum |
| Create | `Memgram/Database/MeetingSegment.swift` | Segment GRDB record |
| Create | `Memgram/Database/Speaker.swift` | Speaker GRDB record |
| Create | `Memgram/Database/MeetingEmbedding.swift` | Embedding GRDB record |
| Create | `Memgram/Database/MeetingStore.swift` | All DB operations |
| Modify | `Memgram/Transcription/TranscriptionEngine.swift` | Add `allChunksDonePublisher` |
| Modify | `Memgram/Audio/RecordingSession.swift` | Wire to MeetingStore |
| Modify | `Memgram/AppDelegate.swift` | Recovery check on launch |
| Modify | `Memgram/UI/MenuBar/PopoverView.swift` | Recovery alert sheet |

---

## Task 1: DB Model Types

**Files:**
- Create: `Memgram/Database/Meeting.swift`
- Create: `Memgram/Database/MeetingSegment.swift`
- Create: `Memgram/Database/Speaker.swift`
- Create: `Memgram/Database/MeetingEmbedding.swift`

- [ ] **Step 1: Create `Meeting.swift`**

```swift
// Memgram/Database/Meeting.swift
import Foundation
import GRDB

enum MeetingStatus: String, Codable, DatabaseValueConvertible {
    case recording, transcribing, done, error
}

struct Meeting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetings"

    var id: String          // UUID string
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double?
    var status: MeetingStatus
    var summary: String?
    var actionItems: String?   // JSON text — decoded by Session 5
    var rawTranscript: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case startedAt       = "started_at"
        case endedAt         = "ended_at"
        case durationSeconds = "duration_seconds"
        case status
        case summary
        case actionItems     = "action_items"
        case rawTranscript   = "raw_transcript"
    }
}
```

- [ ] **Step 2: Create `MeetingSegment.swift`**

```swift
// Memgram/Database/MeetingSegment.swift
import Foundation
import GRDB

struct MeetingSegment: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "segments"

    var id: String          // UUID string
    var meetingId: String
    var speaker: String
    var channel: String
    var startSeconds: Double
    var endSeconds: Double
    var text: String

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId   = "meeting_id"
        case speaker
        case channel
        case startSeconds = "start_seconds"
        case endSeconds   = "end_seconds"
        case text
    }
}
```

- [ ] **Step 3: Create `Speaker.swift`**

```swift
// Memgram/Database/Speaker.swift
import Foundation
import GRDB

struct Speaker: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speakers"

    var id: String
    var meetingId: String
    var label: String
    var customName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId  = "meeting_id"
        case label
        case customName = "custom_name"
    }
}
```

- [ ] **Step 4: Create `MeetingEmbedding.swift`**

```swift
// Memgram/Database/MeetingEmbedding.swift
import Foundation
import GRDB

struct MeetingEmbedding: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "embeddings"

    var id: String
    var meetingId: String
    var chunkText: String
    var embedding: Data     // Float32 BLOB — populated by Session 5
    var model: String

    enum CodingKeys: String, CodingKey {
        case id
        case meetingId = "meeting_id"
        case chunkText = "chunk_text"
        case embedding
        case model
    }
}
```

- [ ] **Step 5: Build to verify models compile**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Memgram/Database/Meeting.swift Memgram/Database/MeetingSegment.swift \
        Memgram/Database/Speaker.swift Memgram/Database/MeetingEmbedding.swift
git commit -m "feat(db): add GRDB model types for meetings, segments, speakers, embeddings"
```

---

## Task 2: AppDatabase Singleton

**Files:**
- Create: `Memgram/Database/AppDatabase.swift`

- [ ] **Step 1: Create `AppDatabase.swift`**

```swift
// Memgram/Database/AppDatabase.swift
import Foundation
import GRDB

final class AppDatabase {
    static let shared: AppDatabase = {
        do { return try AppDatabase() }
        catch { fatalError("Cannot open database: \(error)") }
    }()

    private let dbQueue: DatabaseQueue

    private init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Memgram")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var config = Configuration()
        config.journalMode = .wal

        dbQueue = try DatabaseQueue(
            path: dir.appendingPathComponent("memgram.db").path,
            configuration: config
        )
        try runMigrations()
    }

    // MARK: - Access

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    @discardableResult
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }

    // MARK: - Migrations

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            // meetings
            try db.create(table: "meetings") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("started_at", .double).notNull()
                t.column("ended_at", .double)
                t.column("duration_seconds", .double)
                t.column("status", .text).notNull().defaults(to: "recording")
                t.column("summary", .text)
                t.column("action_items", .text)
                t.column("raw_transcript", .text)
            }

            // segments
            try db.create(table: "segments") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("channel", .text).notNull()
                t.column("start_seconds", .double).notNull()
                t.column("end_seconds", .double).notNull()
                t.column("text", .text).notNull()
            }

            // speakers
            try db.create(table: "speakers") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("custom_name", .text)
            }

            // embeddings
            try db.create(table: "embeddings") { t in
                t.column("id", .text).primaryKey()
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("chunk_text", .text).notNull()
                t.column("embedding", .blob).notNull()
                t.column("model", .text).notNull()
            }

            // FTS5 virtual table (content-backed by segments)
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.content = "segments"
                t.column("text")
                t.column("speaker")
            }

            // Triggers to keep FTS5 in sync with segments
            try db.execute(sql: """
                CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
                    INSERT INTO segments_fts(rowid, text, speaker)
                    VALUES (new.rowid, new.text, new.speaker);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                    VALUES ('delete', old.rowid, old.text, old.speaker);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER segments_au AFTER UPDATE ON segments BEGIN
                    INSERT INTO segments_fts(segments_fts, rowid, text, speaker)
                    VALUES ('delete', old.rowid, old.text, old.speaker);
                    INSERT INTO segments_fts(rowid, text, speaker)
                    VALUES (new.rowid, new.text, new.speaker);
                END
            """)
        }

        try migrator.migrate(dbQueue)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Memgram/Database/AppDatabase.swift
git commit -m "feat(db): add AppDatabase singleton with WAL mode and v1 schema migrations"
```

---

## Task 3: MeetingStore

**Files:**
- Create: `Memgram/Database/MeetingStore.swift`

- [ ] **Step 1: Create `MeetingStore.swift`**

```swift
// Memgram/Database/MeetingStore.swift
import Foundation
import GRDB

final class MeetingStore {
    static let shared = MeetingStore()
    private let db = AppDatabase.shared
    private init() {}

    // MARK: - Write

    @discardableResult
    func createMeeting(title: String) throws -> Meeting {
        let meeting = Meeting(
            id: UUID().uuidString,
            title: title,
            startedAt: Date(),
            endedAt: nil,
            durationSeconds: nil,
            status: .recording,
            summary: nil,
            actionItems: nil,
            rawTranscript: nil
        )
        try db.write { db in try meeting.insert(db) }
        return meeting
    }

    func appendSegment(_ segment: TranscriptSegment, toMeeting meetingId: String) throws {
        let dbSegment = MeetingSegment(
            id: segment.id.uuidString,
            meetingId: meetingId,
            speaker: segment.speaker,
            channel: segment.channel.rawValue,
            startSeconds: segment.startSeconds,
            endSeconds: segment.endSeconds,
            text: segment.text
        )
        try db.write { db in try dbSegment.insert(db) }
    }

    func updateStatus(_ meetingId: String, status: MeetingStatus) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE meetings SET status = ? WHERE id = ?",
                arguments: [status.rawValue, meetingId]
            )
        }
    }

    func finalizeMeeting(_ meetingId: String, endedAt: Date, rawTranscript: String) throws {
        try db.write { db in
            let duration = endedAt.timeIntervalSince(
                (try? Meeting.fetchOne(db, key: meetingId))?.startedAt ?? endedAt
            )
            try db.execute(
                sql: """
                    UPDATE meetings
                    SET status = 'done', ended_at = ?, duration_seconds = ?, raw_transcript = ?
                    WHERE id = ?
                """,
                arguments: [endedAt.timeIntervalSinceReferenceDate, duration, rawTranscript, meetingId]
            )
        }
    }

    func discardMeeting(_ meetingId: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meetingId])
        }
    }

    // MARK: - Read

    func fetchAll() throws -> [Meeting] {
        try db.read { db in
            try Meeting
                .order(Column("started_at").desc)
                .fetchAll(db)
        }
    }

    func fetchMeeting(_ id: String) throws -> Meeting? {
        try db.read { db in try Meeting.fetchOne(db, key: id) }
    }

    func fetchSegments(forMeeting meetingId: String) throws -> [MeetingSegment] {
        try db.read { db in
            try MeetingSegment
                .filter(Column("meeting_id") == meetingId)
                .order(Column("start_seconds"))
                .fetchAll(db)
        }
    }

    func deleteMeeting(_ id: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
        }
    }

    /// Returns meetings that were interrupted (status = recording at last shutdown).
    func interruptedMeetings() throws -> [Meeting] {
        try db.read { db in
            try Meeting
                .filter(Column("status") == MeetingStatus.recording.rawValue)
                .fetchAll(db)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Memgram/Database/MeetingStore.swift
git commit -m "feat(db): add MeetingStore with CRUD, status transitions, and interrupt detection"
```

---

## Task 4: Wire TranscriptionEngine + RecordingSession → MeetingStore

**Files:**
- Modify: `Memgram/Transcription/TranscriptionEngine.swift`
- Modify: `Memgram/Audio/RecordingSession.swift`

- [ ] **Step 1: Add `allChunksDonePublisher` to `TranscriptionEngine`**

Add these properties near the top of `TranscriptionEngine`:

```swift
// After `private var isTranscribing = false`
private let allChunksDoneSubject = PassthroughSubject<Void, Never>()

var allChunksDonePublisher: AnyPublisher<Void, Never> {
    allChunksDoneSubject.eraseToAnyPublisher()
}

/// True when no chunks are queued or in progress.
var isIdle: Bool { !isTranscribing && pendingChunks.isEmpty }
```

Replace the `defer` block inside the `Task` in `drainIfIdle` so it fires the subject when the queue empties:

```swift
// Replace the existing Task block in drainIfIdle with:
Task { [weak self] in
    guard let self else { return }
    do {
        let segments = try await whisper.transcribe(audioFrames: chunk.samples)
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let startSec = chunk.chunkStart + Double(seg.startTime) / 1000.0
            let endSec   = chunk.chunkStart + Double(seg.endTime)   / 1000.0

            let (speaker, channel) = self.determineSpeaker(
                text: text,
                leftEnergy: chunk.leftEnergy,
                rightEnergy: chunk.rightEnergy
            )
            let cleanText = Self.stripDiarizationTags(text)
            guard !cleanText.isEmpty else { continue }

            let segment = TranscriptSegment(
                id: UUID(),
                startSeconds: startSec,
                endSeconds: endSec,
                text: cleanText,
                speaker: speaker,
                channel: channel
            )
            self.subject.send(segment)
        }
    } catch {
        // Non-fatal — skip chunk
    }

    self.isTranscribing = false
    if self.pendingChunks.isEmpty {
        self.allChunksDoneSubject.send()
    } else {
        self.drainIfIdle()
    }
}
```

Also remove the two-line `defer` that was previously there:
```swift
// DELETE these lines from the Task closure:
// defer {
//     self.isTranscribing = false
//     self.drainIfIdle()
// }
```

- [ ] **Step 2: Update `RecordingSession.swift`**

Replace the entire file content:

```swift
// Memgram/Audio/RecordingSession.swift
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

        // Create DB record
        let meeting = try MeetingStore.shared.createMeeting(
            title: "Meeting \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
        )
        currentMeetingId = meeting.id

        // Prepare transcription engine
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

        // Level meters
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

        // Pipe 30s stereo chunks into transcription engine
        chunkCancellable = mixer.chunkPublisher
            .sink { [weak self] chunk in
                self?.transcriptionEngine.transcribe(chunk)
            }

        // Collect segments — save each to DB in real-time
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
        let capturedSegments = segments

        // Mark as transcribing while queue drains
        if let id = meetingId {
            try? MeetingStore.shared.updateStatus(id, status: .transcribing)
        }

        // Tear down audio
        mixer.disconnect()
        micCapture?.stop()
        await sysCapture?.stop()
        micCapture = nil
        sysCapture = nil
        chunkCancellable = nil
        segmentCancellable = nil
        levelCancellables.removeAll()
        micLevel = 0
        sysLevel = 0
        silentSysAudioSeconds = 0
        isRecording = false

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("memgram")
        try? FileManager.default.removeItem(at: tmpDir)

        // Finalize once transcription queue drains
        guard let id = meetingId else { return }

        let finalize = { [weak self] in
            let rawTranscript = capturedSegments
                .map { "\($0.speaker): \($0.text)" }
                .joined(separator: "\n")
            try? MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript)
            self?.currentMeetingId = nil
            self?.finalizationCancellable = nil
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
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/Transcription/TranscriptionEngine.swift Memgram/Audio/RecordingSession.swift
git commit -m "feat(db): wire RecordingSession to MeetingStore — segments persisted in real-time, meeting finalized on stop"
```

---

## Task 5: Recovery Flow on Launch

**Files:**
- Modify: `Memgram/AppDelegate.swift`
- Modify: `Memgram/UI/MenuBar/PopoverView.swift`

- [ ] **Step 1: Trigger recovery check in `AppDelegate`**

In `applicationDidFinishLaunching`, add one line after `showOnboardingIfNeeded()`:

```swift
// Add after showOnboardingIfNeeded():
RecordingSession.shared.loadInterruptedMeetings()
```

- [ ] **Step 2: Add recovery sheet to `PopoverView`**

Add a `@State private var recoveryMeeting: Meeting?` property and a `.sheet` modifier. Replace `PopoverView.body` with the version below that handles the recovery alert:

Add this state property near the existing `@State` declarations:
```swift
@State private var showRecoveryAlert = false
```

Add this modifier to the outermost `VStack` (after the existing `.sheet(isPresented: $showModelDownload)`):
```swift
.alert("Interrupted Recording",
       isPresented: Binding(
           get: { !session.interruptedMeetings.isEmpty },
           set: { _ in }
       ),
       presenting: session.interruptedMeetings.first
) { meeting in
    Button("Recover") { session.recoverMeeting(meeting) }
    Button("Discard", role: .destructive) { session.discardMeeting(meeting) }
} message: { meeting in
    Text(""\(meeting.title)" was interrupted. Recover it as a completed meeting, or discard it?")
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/AppDelegate.swift Memgram/UI/MenuBar/PopoverView.swift
git commit -m "feat(db): show recovery alert for interrupted recordings on launch"
```

---

## Spec Coverage Check

| Requirement | Task |
|-------------|------|
| meetings, segments, speakers, embeddings tables | Task 2 |
| FTS5 virtual table on segments | Task 2 |
| AppDatabase singleton, WAL mode | Task 2 |
| DatabaseMigrator versioned migrations | Task 2 |
| createMeeting, appendSegment, finalizeMeeting, fetchAll, fetchMeeting, fetchSegments, deleteMeeting | Task 3 |
| Segments saved in real-time as they arrive | Task 4 |
| recording → transcribing → done transitions | Task 4 |
| Detect status='recording' on launch, offer recover/discard | Task 5 |
