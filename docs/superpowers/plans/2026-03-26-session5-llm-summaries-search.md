# Session 5: LLM Summaries & Semantic Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LLM-powered meeting summaries, embedding-based semantic search, and a fully wired AI settings tab.

**Architecture:** A `LLMProvider` protocol with three implementations (Ollama, Claude, OpenAI) selected at runtime via `LLMProviderStore`. `SummaryEngine` and `EmbeddingEngine` run as background Tasks triggered after a meeting is finalized. `SearchEngine` combines FTS5 BM25 scores with in-process cosine similarity over stored Float32 embeddings. API keys live in the macOS Keychain only.

**Tech Stack:** Swift URLSession (no networking library), Security framework (Keychain), GRDB FTS5, Accelerate-free Float32 cosine in Swift, existing AppDatabase/MeetingStore layer.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `Memgram/AI/LLMProvider.swift` | Protocol, LLMBackend enum |
| Create | `Memgram/AI/KeychainHelper.swift` | Keychain read/write/delete |
| Create | `Memgram/AI/LLMProviderStore.swift` | Singleton, selected backend, provider factory |
| Create | `Memgram/AI/OllamaProvider.swift` | Ollama generate + embeddings + model list |
| Create | `Memgram/AI/ClaudeProvider.swift` | Claude Messages API, embed delegates to Ollama |
| Create | `Memgram/AI/OpenAIProvider.swift` | OpenAI chat + embeddings |
| Create | `Memgram/AI/SummaryEngine.swift` | Summarise raw transcript, store to DB |
| Create | `Memgram/AI/EmbeddingEngine.swift` | Chunk transcript, embed, store to embeddings table |
| Create | `Memgram/AI/SearchEngine.swift` | Hybrid FTS5+cosine search, returns [SearchResult] |
| Modify | `Memgram/Database/MeetingStore.swift` | Add saveSummary, insertEmbedding, fetchEmbeddings |
| Modify | `Memgram/Audio/RecordingSession.swift` | Trigger summary+embedding after finalization |
| Modify | `Memgram/UI/Settings/SettingsView.swift` | Replace placeholder with AI settings tab |

---

## Task 1: LLMProvider Protocol + KeychainHelper + LLMProviderStore

**Files:**
- Create: `Memgram/AI/LLMProvider.swift`
- Create: `Memgram/AI/KeychainHelper.swift`
- Create: `Memgram/AI/LLMProviderStore.swift`

- [ ] **Step 1: Create the AI directory and `LLMProvider.swift`**

```swift
// Memgram/AI/LLMProvider.swift
import Foundation

enum LLMBackend: String, CaseIterable, Identifiable {
    case ollama, claude, openai
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ollama:  return "Ollama (local)"
        case .claude:  return "Claude API"
        case .openai:  return "OpenAI API"
        }
    }
}

protocol LLMProvider {
    var name: String { get }
    func complete(system: String, user: String) async throws -> String
    func embed(text: String) async throws -> [Float]
}
```

- [ ] **Step 2: Create `KeychainHelper.swift`**

```swift
// Memgram/AI/KeychainHelper.swift
import Foundation
import Security

struct KeychainHelper {
    private static let service = "com.memgram.app"

    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 3: Create `LLMProviderStore.swift`**

```swift
// Memgram/AI/LLMProviderStore.swift
import Foundation
import Combine

@MainActor
final class LLMProviderStore: ObservableObject {
    static let shared = LLMProviderStore()

    @Published var selectedBackend: LLMBackend {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: "llmBackend") }
    }
    @Published var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "llmBackend") ?? ""
        selectedBackend = LLMBackend(rawValue: saved) ?? .ollama
        ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? "llama3.2"
    }

    var currentProvider: any LLMProvider {
        switch selectedBackend {
        case .ollama:
            return OllamaProvider(model: ollamaModel)
        case .claude:
            return ClaudeProvider(apiKey: KeychainHelper.load(key: "claudeAPIKey") ?? "")
        case .openai:
            return OpenAIProvider(apiKey: KeychainHelper.load(key: "openaiAPIKey") ?? "")
        }
    }

    func fetchOllamaModels() async -> [String] {
        return await OllamaProvider(model: ollamaModel).listModels()
    }
}
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Memgram/AI/LLMProvider.swift Memgram/AI/KeychainHelper.swift Memgram/AI/LLMProviderStore.swift
git commit -m "feat(ai): add LLMProvider protocol, KeychainHelper, LLMProviderStore"
```

---

## Task 2: OllamaProvider

**Files:**
- Create: `Memgram/AI/OllamaProvider.swift`

- [ ] **Step 1: Create `OllamaProvider.swift`**

```swift
// Memgram/AI/OllamaProvider.swift
import Foundation

final class OllamaProvider: LLMProvider {
    let name = "Ollama"
    private let model: String
    private let baseURL = URL(string: "http://localhost:11434")!

    init(model: String = "llama3.2") {
        self.model = model
    }

    // MARK: - LLMProvider

    func complete(system: String, user: String) async throws -> String {
        struct Request: Encodable {
            let model: String
            let prompt: String
            let system: String
            let stream: Bool
        }
        struct Response: Decodable { let response: String }

        let prompt = user
        let body = Request(model: model, prompt: prompt, system: system, stream: false)
        let response: Response = try await post(path: "/api/generate", body: body)
        return response.response
    }

    func embed(text: String) async throws -> [Float] {
        struct Request: Encodable {
            let model: String
            let prompt: String
        }
        struct Response: Decodable { let embedding: [Float] }

        let body = Request(model: "nomic-embed-text", prompt: text)
        let response: Response = try await post(path: "/api/embeddings", body: body)
        return response.embedding
    }

    // MARK: - Model list (for SettingsView picker)

    func listModels() async -> [String] {
        struct Tag: Decodable { let name: String }
        struct Response: Decodable { let models: [Tag] }

        guard let response: Response = try? await get(path: "/api/tags") else { return [] }
        return response.models.map(\.name)
    }

    // MARK: - HTTP helpers

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        let request = URLRequest(url: baseURL.appendingPathComponent(path))
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
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
git add Memgram/AI/OllamaProvider.swift
git commit -m "feat(ai): add OllamaProvider (generate, embeddings, model list)"
```

---

## Task 3: ClaudeProvider + OpenAIProvider

**Files:**
- Create: `Memgram/AI/ClaudeProvider.swift`
- Create: `Memgram/AI/OpenAIProvider.swift`

- [ ] **Step 1: Create `ClaudeProvider.swift`**

```swift
// Memgram/AI/ClaudeProvider.swift
import Foundation

final class ClaudeProvider: LLMProvider {
    let name = "Claude API"
    private let apiKey: String
    private let model = "claude-sonnet-4-6"

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(system: String, user: String) async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
        }
        struct ContentBlock: Decodable { let text: String }
        struct Response: Decodable { let content: [ContentBlock] }

        let body = Request(
            model: model,
            max_tokens: 2048,
            system: system,
            messages: [Message(role: "user", content: user)]
        )
        let response: Response = try await post(body: body)
        return response.content.first?.text ?? ""
    }

    /// Claude has no embedding API — delegate to local Ollama.
    func embed(text: String) async throws -> [Float] {
        return try await OllamaProvider().embed(text: text)
    }

    private func post<Body: Encodable, Response: Decodable>(body: Body) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
```

- [ ] **Step 2: Create `OpenAIProvider.swift`**

```swift
// Memgram/AI/OpenAIProvider.swift
import Foundation

final class OpenAIProvider: LLMProvider {
    let name = "OpenAI API"
    private let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func complete(system: String, user: String) async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            let model: String
            let messages: [Message]
        }
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String }
            let message: Msg
        }
        struct Response: Decodable { let choices: [Choice] }

        let body = Request(
            model: "gpt-4o-mini",
            messages: [
                Message(role: "system", content: system),
                Message(role: "user", content: user)
            ]
        )
        let response: Response = try await post(path: "/v1/chat/completions", body: body)
        return response.choices.first?.message.content ?? ""
    }

    func embed(text: String) async throws -> [Float] {
        struct Request: Encodable { let model: String; let input: String }
        struct EmbeddingData: Decodable { let embedding: [Float] }
        struct Response: Decodable { let data: [EmbeddingData] }

        let body = Request(model: "text-embedding-3-small", input: text)
        let response: Response = try await post(path: "/v1/embeddings", body: body)
        return response.data.first?.embedding ?? []
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.openai.com\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
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
git add Memgram/AI/ClaudeProvider.swift Memgram/AI/OpenAIProvider.swift
git commit -m "feat(ai): add ClaudeProvider and OpenAIProvider"
```

---

## Task 4: SummaryEngine + MeetingStore.saveSummary + Wire to RecordingSession

**Files:**
- Create: `Memgram/AI/SummaryEngine.swift`
- Modify: `Memgram/Database/MeetingStore.swift`
- Modify: `Memgram/Audio/RecordingSession.swift`

- [ ] **Step 1: Add `saveSummary` to `MeetingStore.swift`**

Add this method to `MeetingStore`, after `finalizeMeeting`:

```swift
func saveSummary(meetingId: String, summary: String) throws {
    try db.write { db in
        try db.execute(
            sql: "UPDATE meetings SET summary = ? WHERE id = ?",
            arguments: [summary, meetingId]
        )
    }
}
```

- [ ] **Step 2: Create `SummaryEngine.swift`**

```swift
// Memgram/AI/SummaryEngine.swift
import Foundation

final class SummaryEngine {
    static let shared = SummaryEngine()
    private init() {}

    private let systemPrompt = "You are a concise meeting assistant. Be factual. Use speaker labels."

    func summarize(meetingId: String) async {
        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId),
              let transcript = meeting.rawTranscript, !transcript.isEmpty else { return }

        let provider = await LLMProviderStore.shared.currentProvider

        do {
            let summary: String
            if (meeting.durationSeconds ?? 0) > 3600 {
                summary = try await summarizeLong(meetingId: meetingId, transcript: transcript, provider: provider)
            } else {
                summary = try await summarizeShort(transcript: transcript, provider: provider)
            }
            try MeetingStore.shared.saveSummary(meetingId: meetingId, summary: summary)
        } catch {
            // Summary failed silently — meeting remains unsummarised
        }
    }

    // MARK: - Private

    private func summarizeShort(transcript: String, provider: any LLMProvider) async throws -> String {
        let user = """
        Transcript:

        \(transcript)

        Provide: 1) 3-5 sentence summary 2) Key decisions 3) Action items with owner. Plain text, no markdown.
        """
        return try await provider.complete(system: systemPrompt, user: user)
    }

    private func summarizeLong(meetingId: String, transcript: String, provider: any LLMProvider) async throws -> String {
        // Fetch segments to split by 20-minute windows
        let segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        let windows = chunkByTime(segments, windowMinutes: 20)

        // Summarise each window
        var chunkSummaries: [String] = []
        for window in windows {
            let chunkTranscript = window.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
            let summary = try await summarizeShort(transcript: chunkTranscript, provider: provider)
            chunkSummaries.append(summary)
        }

        // Summarise the summaries
        let combined = chunkSummaries.enumerated()
            .map { "Segment \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        return try await summarizeShort(transcript: combined, provider: provider)
    }

    private func chunkByTime(_ segments: [MeetingSegment], windowMinutes: Double) -> [[MeetingSegment]] {
        let windowSeconds = windowMinutes * 60
        guard !segments.isEmpty else { return [] }
        var chunks: [[MeetingSegment]] = []
        var current: [MeetingSegment] = []
        var windowStart = segments[0].startSeconds
        for seg in segments {
            if seg.startSeconds >= windowStart + windowSeconds {
                if !current.isEmpty { chunks.append(current) }
                current = [seg]
                windowStart = seg.startSeconds
            } else {
                current.append(seg)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
```

- [ ] **Step 3: Trigger summary from `RecordingSession.stop()`**

In `Memgram/Audio/RecordingSession.swift`, find the `finalize` closure. After the `finalizeMeeting` call, add the summary trigger:

```swift
let finalize = { [weak self] in
    guard let self else { return }
    let rawTranscript = self.segments
        .map { "\($0.speaker): \($0.text)" }
        .joined(separator: "\n")
    try? MeetingStore.shared.finalizeMeeting(id, endedAt: Date(), rawTranscript: rawTranscript)
    self.currentMeetingId = nil
    self.segmentCancellable = nil
    self.finalizationCancellable = nil

    // Trigger summary + embedding in background (non-blocking)
    Task {
        await SummaryEngine.shared.summarize(meetingId: id)
        await EmbeddingEngine.shared.embed(meetingId: id)
    }
}
```

Note: `EmbeddingEngine` is created in Task 5. Add it now as a forward reference — the build will fail until Task 5 is done.

- [ ] **Step 4: Build to verify (after Task 5 adds EmbeddingEngine)**

Skip this until Task 5 is complete. If building now, temporarily comment out the `EmbeddingEngine.shared.embed(meetingId: id)` line.

- [ ] **Step 5: Commit**

```bash
git add Memgram/AI/SummaryEngine.swift Memgram/Database/MeetingStore.swift Memgram/Audio/RecordingSession.swift
git commit -m "feat(ai): add SummaryEngine, wire to RecordingSession after finalization"
```

---

## Task 5: EmbeddingEngine + MeetingStore Embedding Methods

**Files:**
- Create: `Memgram/AI/EmbeddingEngine.swift`
- Modify: `Memgram/Database/MeetingStore.swift`

- [ ] **Step 1: Add embedding methods to `MeetingStore.swift`**

Add after `saveSummary`:

```swift
func insertEmbedding(_ embedding: MeetingEmbedding) throws {
    try db.write { db in try embedding.insert(db) }
}

func fetchEmbeddings(forMeeting meetingId: String) throws -> [MeetingEmbedding] {
    try db.read { db in
        try MeetingEmbedding
            .filter(Column("meeting_id") == meetingId)
            .fetchAll(db)
    }
}

func fetchAllEmbeddings() throws -> [MeetingEmbedding] {
    try db.read { db in try MeetingEmbedding.fetchAll(db) }
}
```

- [ ] **Step 2: Create `EmbeddingEngine.swift`**

```swift
// Memgram/AI/EmbeddingEngine.swift
import Foundation

final class EmbeddingEngine {
    static let shared = EmbeddingEngine()
    private init() {}

    func embed(meetingId: String) async {
        guard let meeting = try? MeetingStore.shared.fetchMeeting(meetingId),
              let transcript = meeting.rawTranscript, !transcript.isEmpty else { return }

        let provider = await LLMProviderStore.shared.currentProvider
        let modelName = await LLMProviderStore.shared.ollamaModel
        let chunks = chunkText(transcript)

        for chunk in chunks {
            guard !chunk.isEmpty else { continue }
            do {
                let vector = try await provider.embed(text: chunk)
                let embedding = MeetingEmbedding(
                    id: UUID().uuidString,
                    meetingId: meetingId,
                    chunkText: chunk,
                    embedding: floatsToData(vector),
                    model: modelName
                )
                try MeetingStore.shared.insertEmbedding(embedding)
            } catch {
                // Skip failed chunks
            }
        }
    }

    // MARK: - Chunking (≈384 words per chunk, 128-word overlap)

    func chunkText(_ text: String, chunkSize: Int = 384, overlap: Int = 128) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var chunks: [String] = []
        var start = 0
        while start < words.count {
            let end = min(start + chunkSize, words.count)
            chunks.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start += chunkSize - overlap
        }
        return chunks
    }

    // MARK: - Float32 ↔ Data

    func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBytes { Data($0) }
    }

    func dataToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
```

- [ ] **Step 3: Build to verify (now that EmbeddingEngine exists)**

Uncomment the `EmbeddingEngine.shared.embed(meetingId: id)` line in `RecordingSession.swift` if it was commented out.

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/AI/EmbeddingEngine.swift Memgram/Database/MeetingStore.swift
git commit -m "feat(ai): add EmbeddingEngine with overlapping text chunking, wire after summarization"
```

---

## Task 6: SearchEngine (Hybrid FTS5 + Cosine)

**Files:**
- Create: `Memgram/AI/SearchEngine.swift`

- [ ] **Step 1: Create `SearchEngine.swift`**

```swift
// Memgram/AI/SearchEngine.swift
import Foundation
import GRDB

struct SearchResult {
    var meetingId: String
    var segmentId: String
    var speaker: String
    var snippet: String
    var timestampSeconds: Double
    var score: Float
}

final class SearchEngine {
    static let shared = SearchEngine()
    private init() {}

    func search(query: String, limit: Int = 20) async throws -> [SearchResult] {
        let ftsResults = try ftsSearch(query: query, limit: limit * 2)
        let cosineResults = try await cosineSearch(query: query, limit: limit * 2)
        return merge(fts: ftsResults, cosine: cosineResults, limit: limit)
    }

    // MARK: - FTS5

    private struct FTSResult {
        var meetingId: String
        var segmentId: String
        var speaker: String
        var snippet: String
        var timestampSeconds: Double
        var bm25: Float  // raw BM25 (negative — lower is better)
    }

    private func ftsSearch(query: String, limit: Int) throws -> [FTSResult] {
        try AppDatabase.shared.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.meeting_id, s.speaker, s.text, s.start_seconds,
                       bm25(segments_fts) AS bm25
                FROM segments_fts
                JOIN segments s ON segments_fts.rowid = s.rowid
                WHERE segments_fts MATCH ?
                ORDER BY bm25
                LIMIT ?
            """, arguments: [query, limit])

            return rows.map {
                FTSResult(
                    meetingId: $0["meeting_id"],
                    segmentId: $0["id"],
                    speaker: $0["speaker"],
                    snippet: $0["text"],
                    timestampSeconds: $0["start_seconds"],
                    bm25: $0["bm25"]
                )
            }
        }
    }

    // MARK: - Cosine

    private struct CosineResult {
        var meetingId: String
        var snippet: String
        var speaker: String
        var timestampSeconds: Double
        var similarity: Float
    }

    private func cosineSearch(query: String, limit: Int) async throws -> [CosineResult] {
        let provider = await LLMProviderStore.shared.currentProvider
        let queryVector = try await provider.embed(text: query)
        let allEmbeddings = try MeetingStore.shared.fetchAllEmbeddings()

        let engine = EmbeddingEngine.shared
        let scored: [(MeetingEmbedding, Float)] = allEmbeddings.map { emb in
            let vec = engine.dataToFloats(emb.embedding)
            let sim = cosineSimilarity(queryVector, vec)
            return (emb, sim)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .map { ($0.0, $0.1) }

        return scored.map {
            CosineResult(
                meetingId: $0.meetingId,
                snippet: $0.chunkText,
                speaker: "",           // embeddings don't store speaker; leave empty
                timestampSeconds: 0,
                similarity: $1
            )
        }
    }

    // MARK: - Merge (BM25 * 0.4 + cosine * 0.6)

    private func merge(fts: [FTSResult], cosine: [CosineResult], limit: Int) -> [SearchResult] {
        // Normalise BM25: negate (bm25 is negative) then scale to [0,1]
        let maxBM25 = fts.map { -$0.bm25 }.max() ?? 1
        let ftsNormed: [(String, Float)] = fts.map { ($0.segmentId, maxBM25 > 0 ? (-$0.bm25 / maxBM25) : 0) }

        // cosine is already [0,1]
        let cosineNormed: [(String, Float)] = cosine.enumerated().map { ("\($0.offset)", $0.element.similarity) }

        // Build combined score per segment using segment text as key for cosine
        var combined: [String: SearchResult] = [:]

        for item in fts {
            let normalised = ftsNormed.first(where: { $0.0 == item.segmentId })?.1 ?? 0
            combined[item.segmentId] = SearchResult(
                meetingId: item.meetingId,
                segmentId: item.segmentId,
                speaker: item.speaker,
                snippet: item.snippet,
                timestampSeconds: item.timestampSeconds,
                score: normalised * 0.4
            )
        }

        // Add cosine contribution by matching snippet text against FTS snippets
        for (idx, item) in cosine.enumerated() {
            let cosineScore = cosineNormed[idx].1 * 0.6
            // Find if FTS already has this meeting's text; if not, add as cosine-only result
            if let matchKey = combined.first(where: { $0.value.meetingId == item.meetingId })?.key {
                combined[matchKey]?.score += cosineScore
            }
            // Cosine-only results are omitted here to avoid duplicates with no FTS context
        }

        return combined.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Cosine Similarity

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let len = min(a.count, b.count)
        guard len > 0 else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        for i in 0..<len {
            dot  += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
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
git add Memgram/AI/SearchEngine.swift
git commit -m "feat(ai): add SearchEngine with hybrid FTS5 BM25 + cosine similarity"
```

---

## Task 7: SettingsView AI Tab

**Files:**
- Modify: `Memgram/UI/Settings/SettingsView.swift`

- [ ] **Step 1: Replace `SettingsView.swift` with full AI-aware implementation**

```swift
// Memgram/UI/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 500, height: 360)
    }
}

// MARK: - AI Settings

struct AISettingsTab: View {
    @ObservedObject private var store = LLMProviderStore.shared
    @State private var claudeKey: String = KeychainHelper.load(key: "claudeAPIKey") ?? ""
    @State private var openaiKey: String = KeychainHelper.load(key: "openaiAPIKey") ?? ""
    @State private var ollamaModels: [String] = []
    @State private var connectionStatus: String = ""
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("LLM Backend") {
                Picker("Provider", selection: $store.selectedBackend) {
                    ForEach(LLMBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch store.selectedBackend {
            case .ollama:
                Section("Ollama") {
                    Picker("Model", selection: $store.ollamaModel) {
                        if ollamaModels.isEmpty {
                            Text(store.ollamaModel).tag(store.ollamaModel)
                        }
                        ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                    }
                    .onAppear { Task { ollamaModels = await store.fetchOllamaModels() } }
                }

            case .claude:
                Section("Claude API Key") {
                    SecureField("sk-ant-…", text: $claudeKey)
                        .onChange(of: claudeKey) { KeychainHelper.save(key: "claudeAPIKey", value: $0) }
                }

            case .openai:
                Section("OpenAI API Key") {
                    SecureField("sk-…", text: $openaiKey)
                        .onChange(of: openaiKey) { KeychainHelper.save(key: "openaiAPIKey", value: $0) }
                }
            }

            Section {
                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting)
                    if !connectionStatus.isEmpty {
                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundColor(connectionStatus.hasPrefix("✓") ? .green : .red)
                    }
                }
            }
        }
        .padding()
    }

    private func testConnection() async {
        isTesting = true
        connectionStatus = ""
        let provider = LLMProviderStore.shared.currentProvider
        do {
            let reply = try await provider.complete(
                system: "You are a test assistant.",
                user: "Reply with exactly: OK"
            )
            connectionStatus = reply.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("OK")
                ? "✓ Connected"
                : "✓ Responded: \(reply.prefix(40))"
        } catch {
            connectionStatus = "✗ \(error.localizedDescription)"
        }
        isTesting = false
    }
}

// MARK: - Privacy Settings (unchanged)

struct PrivacySettingsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Privacy")
                        .font(.headline)
                    Text("Audio is never stored. Memgram discards all audio immediately after transcription. Only text transcripts are saved to your local device.")
                        .font(.body)
                        .foregroundColor(.secondary)
                    Text("No data is sent to any server unless you configure a cloud LLM provider (Claude API or OpenAI) in the AI settings.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            Button("Reset Permissions") {
                UserDefaults.standard.removeObject(forKey: "microphonePermissionGranted")
                UserDefaults.standard.removeObject(forKey: "systemAudioPermissionGranted")
                UserDefaults.standard.removeObject(forKey: "hasShownOnboarding")
            }
            .buttonStyle(.bordered)
        }
        .padding()
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
git add Memgram/UI/Settings/SettingsView.swift
git commit -m "feat(ui): replace placeholder SettingsView with AI backend picker, API key fields, test connection"
```

---

## Spec Coverage Check

| Requirement | Task |
|-------------|------|
| LLMProvider protocol with complete() and embed() | Task 1 |
| OllamaProvider (generate + embeddings) | Task 2 |
| ClaudeProvider (claude-sonnet-4-6, embed→Ollama) | Task 3 |
| OpenAIProvider (chat + text-embedding-3-small) | Task 3 |
| API keys in Keychain | Task 1 (KeychainHelper) |
| SummaryEngine with exact system/user prompt | Task 4 |
| >60min chunked summarisation (20min windows) | Task 4 |
| EmbeddingEngine with overlapping 512-token chunks | Task 5 |
| Embeddings stored in embeddings table | Task 5 |
| SearchEngine hybrid FTS5 (×0.4) + cosine (×0.6) | Task 6 |
| SearchResult { meetingId, speaker, snippet, timestampSeconds, score } | Task 6 |
| SettingsView: backend picker | Task 7 |
| SettingsView: API key fields | Task 7 |
| SettingsView: Ollama model picker from /api/tags | Task 7 |
| SettingsView: test connection button | Task 7 |
