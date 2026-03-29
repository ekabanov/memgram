# Streaming Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show AI-generated meeting summaries appearing word-by-word in real time instead of waiting for the full response.

**Architecture:** Add a `stream()` method to the `LLMProvider` protocol (with a default fallback to `complete()` so Qwen works without changes). Each cloud provider implements SSE streaming. `SummaryEngine` accumulates streamed tokens and writes them to a `@Published streamingText` dictionary; `MeetingDetailView` renders from that dictionary while generation is in progress, then switches to the DB-persisted summary when done.

**Tech Stack:** Swift `AsyncThrowingStream`, `URLSession.bytes(for:)` for SSE, existing `MarkdownUI` rendering.

---

## Task 1: Add `stream()` to LLMProvider Protocol with Default Fallback

**Files:**
- Modify: `Memgram/AI/LLMProvider.swift`

- [ ] **Step 1: Read the file**

Run: `cat -n Memgram/AI/LLMProvider.swift`

- [ ] **Step 2: Add `stream()` to the protocol and provide default extension**

Replace the `protocol LLMProvider` block and everything after it with:

```swift
protocol LLMProvider {
    var name: String { get }
    func complete(system: String, user: String) async throws -> String
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error>
    func embed(text: String) async throws -> [Float]
}

extension LLMProvider {
    /// Default: wraps complete() — yields the full response as a single chunk.
    /// Providers that support real streaming override this.
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.complete(system: system, user: user)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/AI/LLMProvider.swift
git commit -m "feat: add stream() to LLMProvider protocol with default complete() fallback"
```

---

## Task 2: Implement SSE Streaming in ClaudeProvider

**Files:**
- Modify: `Memgram/AI/ClaudeProvider.swift`

- [ ] **Step 1: Read the file**

Run: `cat -n Memgram/AI/ClaudeProvider.swift`

- [ ] **Step 2: Add `stream()` method**

Add this method to `ClaudeProvider` after `complete()`:

```swift
func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                struct Message: Encodable { let role: String; let content: String }
                struct Request: Encodable {
                    let model: String; let max_tokens: Int; let stream: Bool
                    let system: String; let messages: [Message]
                }
                let body = Request(
                    model: model, max_tokens: 2048, stream: true,
                    system: system,
                    messages: [Message(role: "user", content: user)]
                )
                var request = URLRequest(
                    url: URL(string: "https://api.anthropic.com/v1/messages")!,
                    timeoutInterval: 600
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(self.apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.httpBody = try JSONEncoder().encode(body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                struct Delta: Decodable { let type: String; let text: String? }
                struct StreamEvent: Decodable { let type: String; let delta: Delta? }

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let json = String(line.dropFirst(6))
                    guard json != "[DONE]" else { break }
                    guard let data = json.data(using: .utf8),
                          let event = try? JSONDecoder().decode(StreamEvent.self, from: data),
                          event.type == "content_block_delta",
                          event.delta?.type == "text_delta",
                          let text = event.delta?.text else { continue }
                    continuation.yield(text)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/AI/ClaudeProvider.swift
git commit -m "feat: implement SSE streaming in ClaudeProvider"
```

---

## Task 3: Implement SSE Streaming in OpenAIProvider

**Files:**
- Modify: `Memgram/AI/OpenAIProvider.swift`

- [ ] **Step 1: Read the file**

Run: `cat -n Memgram/AI/OpenAIProvider.swift`

- [ ] **Step 2: Add `stream()` method**

Add this method to `OpenAIProvider` after `complete()`:

```swift
func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                struct Message: Encodable { let role: String; let content: String }
                struct Request: Encodable {
                    let model: String; let messages: [Message]; let stream: Bool
                }
                let body = Request(
                    model: "gpt-4o-mini",
                    messages: [
                        Message(role: "system", content: system),
                        Message(role: "user",   content: user)
                    ],
                    stream: true
                )
                var request = URLRequest(
                    url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                    timeoutInterval: 600
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder().encode(body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                struct Delta: Decodable { let content: String? }
                struct Choice: Decodable { let delta: Delta }
                struct StreamChunk: Decodable { let choices: [Choice] }

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let json = String(line.dropFirst(6))
                    guard json != "[DONE]" else { break }
                    guard let data = json.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                          let text = chunk.choices.first?.delta.content else { continue }
                    continuation.yield(text)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/AI/OpenAIProvider.swift
git commit -m "feat: implement SSE streaming in OpenAIProvider"
```

---

## Task 4: Implement SSE Streaming in CustomServerProvider

**Files:**
- Modify: `Memgram/AI/CustomServerProvider.swift`

- [ ] **Step 1: Read the file**

Run: `cat -n Memgram/AI/CustomServerProvider.swift`

- [ ] **Step 2: Add `stream()` method**

Add this method to `CustomServerProvider` after `complete()`:

```swift
func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                struct Message: Encodable { let role: String; let content: String }
                struct Request: Encodable {
                    let model: String; let messages: [Message]; let stream: Bool
                }
                let body = Request(
                    model: self.modelName,
                    messages: [
                        Message(role: "system", content: system),
                        Message(role: "user",   content: user)
                    ],
                    stream: true
                )
                guard let url = URL(string: "\(self.baseURL)/v1/chat/completions") else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: url, timeoutInterval: 600)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !self.apiKey.isEmpty {
                    request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = try JSONEncoder().encode(body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                struct Delta: Decodable { let content: String? }
                struct Choice: Decodable { let delta: Delta }
                struct StreamChunk: Decodable { let choices: [Choice] }

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let json = String(line.dropFirst(6))
                    guard json != "[DONE]" else { break }
                    guard let data = json.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                          let text = chunk.choices.first?.delta.content else { continue }
                    continuation.yield(text)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/AI/CustomServerProvider.swift
git commit -m "feat: implement SSE streaming in CustomServerProvider"
```

---

## Task 5: Implement SSE Streaming in GeminiProvider

**Files:**
- Modify: `Memgram/AI/GeminiProvider.swift`

- [ ] **Step 1: Read the file**

Run: `cat -n Memgram/AI/GeminiProvider.swift`

- [ ] **Step 2: Add `stream()` method**

Gemini uses `streamGenerateContent` with `?alt=sse`. Add this method after `complete()`:

```swift
func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                struct Part: Encodable { let text: String }
                struct SystemInstruction: Encodable { let parts: [Part] }
                struct ContentItem: Encodable { let role: String; let parts: [Part] }
                struct Request: Encodable {
                    let systemInstruction: SystemInstruction
                    let contents: [ContentItem]
                }
                let body = Request(
                    systemInstruction: .init(parts: [Part(text: system)]),
                    contents: [ContentItem(role: "user", parts: [Part(text: user)])]
                )
                let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(self.model):streamGenerateContent?key=\(self.apiKey)&alt=sse"
                guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
                var request = URLRequest(url: url, timeoutInterval: 600)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(body)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }

                struct GPart: Decodable { let text: String }
                struct GContent: Decodable { let parts: [GPart] }
                struct GCandidate: Decodable { let content: GContent }
                struct GStreamEvent: Decodable { let candidates: [GCandidate] }

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let json = String(line.dropFirst(6))
                    guard let data = json.data(using: .utf8),
                          let event = try? JSONDecoder().decode(GStreamEvent.self, from: data),
                          let text = event.candidates.first?.content.parts.first?.text else { continue }
                    continuation.yield(text)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/AI/GeminiProvider.swift
git commit -m "feat: implement SSE streaming in GeminiProvider"
```

---

## Task 6: Stream Tokens Through SummaryEngine

**Files:**
- Modify: `Memgram/AI/SummaryEngine.swift`

This is the core change. `SummaryEngine` gets a `streamingText` dictionary and all summarize methods accept an `onChunk` callback.

- [ ] **Step 1: Read SummaryEngine.swift**

Run: `cat -n Memgram/AI/SummaryEngine.swift`

- [ ] **Step 2: Add `streamingText` published property**

In the `SummaryEngine` class body, after `@Published var activeMeetingIds`, add:

```swift
/// Partial summary text being streamed, keyed by meetingId.
/// Non-nil only while generation is in progress for that meeting.
@Published private(set) var streamingText: [String: String] = [:]
```

- [ ] **Step 3: Update `summarize()` to set up streaming and clear on finish**

In `summarize(meetingId:overrideBackend:)`, after the line that sets `activeMeetingIds.insert(meetingId)` (or at the start of the do block), add the `onChunk` closure and pass it to the summarize calls.

Find the two lines that call `summarizeShort` or `summarizeLong`:
```swift
summary = try await summarizeLong(meetingId: meetingId, calendarContext: calendarCtx, provider: provider)
// and
summary = try await summarizeShort(transcript: transcript, calendarContext: calendarCtx, provider: provider)
```

Replace them with:
```swift
// Closure that updates streamingText after stripping think-tags.
// Suppressed while a <think> block is still open (Qwen reasoning models).
let onChunk: (String) -> Void = { [weak self] accumulated in
    guard let self else { return }
    let isThinking = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix("<think>") && !accumulated.contains("</think>")
    if !isThinking {
        let visible = self.stripThinkingTags(accumulated)
        if !visible.isEmpty {
            Task { @MainActor [weak self] in
                self?.streamingText[meetingId] = visible
            }
        }
    }
}

if (meeting.durationSeconds ?? 0) > 3600 {
    summary = try await summarizeLong(meetingId: meetingId, calendarContext: calendarCtx,
                                      provider: provider, onChunk: onChunk)
} else {
    summary = try await summarizeShort(transcript: transcript, calendarContext: calendarCtx,
                                       provider: provider, onChunk: onChunk)
}
```

After the `try MeetingStore.shared.saveSummary(...)` line, clear the streaming text:
```swift
streamingText.removeValue(forKey: meetingId)
```

In the `catch` block (error handling), also clear it:
```swift
streamingText.removeValue(forKey: meetingId)
```

- [ ] **Step 4: Update `summarizeShort` signature and body to use `stream()`**

Change:
```swift
private func summarizeShort(transcript: String, calendarContext: CalendarContext?, provider: any LLMProvider) async throws -> String {
```
to:
```swift
private func summarizeShort(transcript: String, calendarContext: CalendarContext?,
                             provider: any LLMProvider,
                             onChunk: ((String) -> Void)? = nil) async throws -> String {
```

At the end of `summarizeShort`, replace:
```swift
return try await provider.complete(system: systemPrompt, user: user)
```
with:
```swift
var accumulated = ""
for try await chunk in provider.stream(system: systemPrompt, user: user) {
    accumulated += chunk
    onChunk?(accumulated)
}
return accumulated
```

- [ ] **Step 5: Update `summarizeLong` to accept and forward `onChunk`**

Change:
```swift
private func summarizeLong(meetingId: String, calendarContext: CalendarContext?, provider: any LLMProvider) async throws -> String {
```
to:
```swift
private func summarizeLong(meetingId: String, calendarContext: CalendarContext?,
                            provider: any LLMProvider,
                            onChunk: ((String) -> Void)? = nil) async throws -> String {
```

In the body of `summarizeLong`, find the call to `summarizeFinal` and add the `onChunk` parameter:
```swift
return try await summarizeFinal(chunkSummaries: chunkSummaries, provider: provider, onChunk: onChunk)
```

(Individual chunk `summarizeShort` calls inside `summarizeLong` do NOT get `onChunk` — we only stream the final merge pass.)

- [ ] **Step 6: Update `summarizeFinal` to accept and stream**

Change:
```swift
private func summarizeFinal(chunkSummaries: [String], provider: any LLMProvider) async throws -> String {
```
to:
```swift
private func summarizeFinal(chunkSummaries: [String], provider: any LLMProvider,
                             onChunk: ((String) -> Void)? = nil) async throws -> String {
```

At the end of `summarizeFinal`, replace:
```swift
return try await provider.complete(system: systemPrompt, user: user)
```
with:
```swift
var accumulated = ""
for try await chunk in provider.stream(system: systemPrompt, user: user) {
    accumulated += chunk
    onChunk?(accumulated)
}
return accumulated
```

- [ ] **Step 7: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add Memgram/AI/SummaryEngine.swift
git commit -m "feat: stream LLM tokens through SummaryEngine with real-time streamingText updates"
```

---

## Task 7: Show Streaming Text in MeetingDetailView

**Files:**
- Modify: `Memgram/UI/MainWindow/MeetingDetailView.swift`

- [ ] **Step 1: Read the summary tab rendering section**

Run: `grep -n "summary\|Markdown\|isRegenerating\|activeMeeting\|streamingText" Memgram/UI/MainWindow/MeetingDetailView.swift | head -30`

- [ ] **Step 2: Add SummaryEngine observation if not already present**

Check if `SummaryEngine.shared` is already observed. The file already has:
```swift
@ObservedObject private var summaryEngine = SummaryEngine.shared
```
If not present, add it after the existing `@ObservedObject` properties.

- [ ] **Step 3: Replace the summary content view to show streaming text**

Find the section in `MeetingDetailView` that renders the summary tab — it looks like:
```swift
if let summary = meeting?.summary, !summary.isEmpty {
    Markdown(summary)
        .markdownTheme(.gitHub)
        .textSelection(.enabled)
} else if isRegenerating {
    // skeleton placeholder
} else {
    Text("No summary yet...")
}
```

Replace with:
```swift
// Prefer live streaming text while generation is active
let streamingContent = summaryEngine.streamingText[meetingId]
let isStreaming = streamingContent != nil

if let live = streamingContent, !live.isEmpty {
    ScrollView {
        Markdown(live)
            .markdownTheme(.gitHub)
            .textSelection(.enabled)
            .padding()
    }
    .overlay(alignment: .bottomTrailing) {
        // Subtle "generating" indicator in corner
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text("Generating…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
} else if let summary = meeting?.summary, !summary.isEmpty {
    Markdown(summary)
        .markdownTheme(.gitHub)
        .textSelection(.enabled)
} else if isRegenerating || summaryEngine.activeMeetingIds.contains(meetingId) {
    // skeleton placeholder while waiting for first tokens
    VStack(spacing: 8) {
        ForEach(0..<6, id: \.self) { i in
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(maxWidth: i % 3 == 2 ? 200 : .infinity)
                .frame(height: 12)
        }
    }
    .padding()
} else {
    Text("No summary yet. Click Generate Summary to create one.")
        .foregroundColor(.secondary)
}
```

**Note:** If the existing skeleton placeholder code is more elaborate, preserve its exact structure — just add the streaming content block above it. Read the file first to understand the exact existing code.

- [ ] **Step 4: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Memgram/UI/MainWindow/MeetingDetailView.swift
git commit -m "feat: show streaming summary text in MeetingDetailView while generating"
```

---

## Task 8: Final Build and Push

- [ ] **Step 1: Release build**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Release build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Push**

```bash
git push
```
