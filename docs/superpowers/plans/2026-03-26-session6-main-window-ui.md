# Session 6: Main Window UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder main window with a full meeting browser: grouped list sidebar, rich detail pane with editable title/summary/action items/transcript, speaker renaming popover, and a Cmd+F search overlay.

**Architecture:** `MainWindowView` owns a `NavigationSplitView` with `MeetingListView` (sidebar) and `MeetingDetailView` (detail). `MeetingDetailView` composes `SegmentRowView` rows that each host a `SpeakerRenameView` popover. `SearchView` is a sheet presented from `MainWindowView`. All data access goes through `MeetingStore.shared`; speaker rename and title edit need two new DB methods added there.

**Tech Stack:** SwiftUI NavigationSplitView, GRDB via MeetingStore, NSPasteboard (timestamp copy), UserDefaults (action item checked state).

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Replace | `Memgram/UI/MainWindow/MainWindowView.swift` | NavigationSplitView root, Cmd+F handler, SearchView sheet |
| Create | `Memgram/UI/MainWindow/MeetingListView.swift` | Grouped sidebar, swipe-to-delete confirmation |
| Create | `Memgram/UI/MainWindow/MeetingDetailView.swift` | Header (editable title), summary, action items |
| Create | `Memgram/UI/MainWindow/SegmentRowView.swift` | Speaker chip, timestamp copy, transcript text |
| Create | `Memgram/UI/MainWindow/SpeakerRenameView.swift` | Rename popover — this meeting vs all meetings |
| Create | `Memgram/UI/MainWindow/SearchView.swift` | Search overlay, enriched results list |
| Delete | `Memgram/UI/MainWindow/MainWindowPlaceholderView.swift` | Replaced by MainWindowView |
| Modify | `Memgram/AppDelegate.swift` | Swap PlaceholderView → MainWindowView |
| Modify | `Memgram/Database/MeetingStore.swift` | Add updateTitle, renameSpeaker, renameSpeakerGlobally |

---

## Task 1: MainWindowView + MeetingListView + AppDelegate wire

**Files:**
- Create: `Memgram/UI/MainWindow/MainWindowView.swift`
- Create: `Memgram/UI/MainWindow/MeetingListView.swift`
- Delete: `Memgram/UI/MainWindow/MainWindowPlaceholderView.swift`
- Modify: `Memgram/AppDelegate.swift`

- [ ] **Step 1: Create `MainWindowView.swift`**

```swift
// Memgram/UI/MainWindow/MainWindowView.swift
import SwiftUI

struct MainWindowView: View {
    @State private var selectedMeetingId: String?
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView {
            MeetingListView(selectedMeetingId: $selectedMeetingId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let id = selectedMeetingId {
                MeetingDetailView(meetingId: id)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView(onSelectMeeting: { id in
                selectedMeetingId = id
            })
        }
        .background {
            // Hidden button captures Cmd+F anywhere in the window
            Button("") { showSearch = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No meetings yet")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Start recording from the menu bar")
                .font(.body)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Create `MeetingListView.swift`**

```swift
// Memgram/UI/MainWindow/MeetingListView.swift
import SwiftUI

extension Meeting: Identifiable {}

struct MeetingListView: View {
    @Binding var selectedMeetingId: String?
    @State private var meetings: [Meeting] = []
    @State private var meetingToDelete: Meeting?
    @State private var showDeleteAlert = false

    var body: some View {
        List(selection: $selectedMeetingId) {
            if meetings.isEmpty {
                Text("No recordings yet")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                ForEach(groupedSections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.meetings) { meeting in
                            MeetingRowView(meeting: meeting)
                                .tag(meeting.id)
                                .contextMenu {
                                    Button("Delete Recording…", role: .destructive) {
                                        meetingToDelete = meeting
                                        showDeleteAlert = true
                                    }
                                }
                        }
                    }
                }
            }
        }
        .navigationTitle("Meetings")
        .onAppear { load() }
        .alert("Delete Recording?", isPresented: $showDeleteAlert, presenting: meetingToDelete) { meeting in
            Button("Delete", role: .destructive) { delete(meeting) }
            Button("Cancel", role: .cancel) {}
        } message: { meeting in
            Text(""\(meeting.title)" will be permanently deleted.")
        }
    }

    // MARK: - Grouping

    private struct Section { let title: String; let meetings: [Meeting] }

    private var groupedSections: [Section] {
        let cal = Calendar.current
        let now = Date()
        let todayStart     = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let weekStart      = cal.date(byAdding: .day, value: -7, to: todayStart)!

        var today: [Meeting] = [], yesterday: [Meeting] = [],
            thisWeek: [Meeting] = [], earlier: [Meeting] = []

        for m in meetings {
            if m.startedAt >= todayStart          { today.append(m) }
            else if m.startedAt >= yesterdayStart { yesterday.append(m) }
            else if m.startedAt >= weekStart      { thisWeek.append(m) }
            else                                   { earlier.append(m) }
        }

        return [("Today", today), ("Yesterday", yesterday),
                ("This Week", thisWeek), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
            .map { Section(title: $0.0, meetings: $0.1) }
    }

    private func load() {
        meetings = (try? MeetingStore.shared.fetchAll()) ?? []
    }

    private func delete(_ meeting: Meeting) {
        try? MeetingStore.shared.deleteMeeting(meeting.id)
        if selectedMeetingId == meeting.id { selectedMeetingId = nil }
        load()
    }
}

// MARK: - Row

struct MeetingRowView: View {
    let meeting: Meeting

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch meeting.status {
        case .recording:    return .red
        case .transcribing: return .orange
        case .done:         return .green
        case .error:        return Color.red.opacity(0.5)
        }
    }

    private var subtitle: String {
        let time = DateFormatter.localizedString(from: meeting.startedAt,
                                                  dateStyle: .none, timeStyle: .short)
        guard let dur = meeting.durationSeconds else { return time }
        let mins = Int(dur / 60)
        return mins > 0 ? "\(time) · \(mins)m" : time
    }
}
```

- [ ] **Step 3: Delete the placeholder and update AppDelegate**

Delete `Memgram/UI/MainWindow/MainWindowPlaceholderView.swift`.

In `Memgram/AppDelegate.swift`, find the `openMainWindow` method and change:

```swift
// BEFORE
let hostingController = NSHostingController(rootView: MainWindowPlaceholderView())
```

```swift
// AFTER
let hostingController = NSHostingController(rootView: MainWindowView())
```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Memgram/UI/MainWindow/MainWindowView.swift Memgram/UI/MainWindow/MeetingListView.swift \
        Memgram/AppDelegate.swift
git rm Memgram/UI/MainWindow/MainWindowPlaceholderView.swift
git commit -m "feat(ui): add MainWindowView with NavigationSplitView and grouped MeetingListView"
```

---

## Task 2: MeetingDetailView (header, summary, action items) + MeetingStore.updateTitle

**Files:**
- Create: `Memgram/UI/MainWindow/MeetingDetailView.swift`
- Modify: `Memgram/Database/MeetingStore.swift`

- [ ] **Step 1: Add `updateTitle` to `MeetingStore.swift`**

Add after `saveSummary`:

```swift
func updateTitle(_ meetingId: String, title: String) throws {
    try db.write { db in
        try db.execute(
            sql: "UPDATE meetings SET title = ? WHERE id = ?",
            arguments: [title, meetingId]
        )
    }
}
```

- [ ] **Step 2: Create `MeetingDetailView.swift`**

```swift
// Memgram/UI/MainWindow/MeetingDetailView.swift
import SwiftUI

extension MeetingSegment: Identifiable {}

struct MeetingDetailView: View {
    let meetingId: String
    @State private var meeting: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var editableTitle = ""
    @State private var isEditingTitle = false
    @State private var refreshID = UUID()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                if let m = meeting, let summary = m.summary, !summary.isEmpty {
                    summarySection(summary)
                }
                if let m = meeting {
                    let items = actionItems(from: m)
                    if !items.isEmpty { actionItemsSection(items, meetingId: m.id) }
                }
                if !segments.isEmpty {
                    transcriptSection
                }
            }
            .padding(24)
        }
        .id(refreshID)
        .onAppear { load() }
        .onChange(of: meetingId) { _ in load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditingTitle {
                TextField("Title", text: $editableTitle, onCommit: saveTitle)
                    .textFieldStyle(.plain)
                    .font(.title.bold())
            } else {
                Text(editableTitle.isEmpty ? "Untitled" : editableTitle)
                    .font(.title.bold())
                    .onTapGesture { isEditingTitle = true }
            }
            if let m = meeting {
                HStack(spacing: 8) {
                    Text(DateFormatter.localizedString(from: m.startedAt,
                                                       dateStyle: .long, timeStyle: .short))
                    if let dur = m.durationSeconds, dur > 0 {
                        Text("·")
                        Text("\(Int(dur / 60))m \(Int(dur.truncatingRemainder(dividingBy: 60)))s")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Summary

    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Summary", systemImage: "text.alignleft")
                .font(.headline)
            Text(summary)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    // MARK: - Action Items

    private func actionItems(from meeting: Meeting) -> [String] {
        guard let json = meeting.actionItems,
              let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return items
    }

    private func actionItemsSection(_ items: [String], meetingId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Action Items", systemImage: "checkmark.circle")
                .font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                ActionItemRow(text: item, meetingId: meetingId, index: idx)
            }
        }
    }

    // MARK: - Transcript

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Transcript", systemImage: "waveform.and.mic")
                .font(.headline)
            ForEach(segments) { segment in
                SegmentRowView(
                    segment: segment,
                    meetingStartedAt: meeting?.startedAt ?? Date(),
                    onSpeakerRenamed: {
                        load()
                        refreshID = UUID()
                    }
                )
                Divider()
            }
        }
    }

    // MARK: - Data

    private func load() {
        meeting  = try? MeetingStore.shared.fetchMeeting(meetingId)
        segments = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        editableTitle = meeting?.title ?? ""
        isEditingTitle = false
    }

    private func saveTitle() {
        let trimmed = editableTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { isEditingTitle = false; return }
        try? MeetingStore.shared.updateTitle(meetingId, title: trimmed)
        isEditingTitle = false
    }
}

// MARK: - Action Item Row

private struct ActionItemRow: View {
    let text: String
    let meetingId: String
    let index: Int

    @State private var isChecked: Bool

    init(text: String, meetingId: String, index: Int) {
        self.text = text
        self.meetingId = meetingId
        self.index = index
        _isChecked = State(initialValue:
            UserDefaults.standard.bool(forKey: "actionChecked_\(meetingId)_\(index)")
        )
    }

    var body: some View {
        Toggle(isOn: $isChecked) {
            Text(text)
                .strikethrough(isChecked)
                .foregroundColor(isChecked ? .secondary : .primary)
        }
        .toggleStyle(.checkbox)
        .onChange(of: isChecked) { newValue in
            UserDefaults.standard.set(newValue, forKey: "actionChecked_\(meetingId)_\(index)")
        }
    }
}
```

- [ ] **Step 3: Build to verify (SegmentRowView is referenced but not yet created — add a stub)**

Add a stub file so it compiles:

```swift
// Memgram/UI/MainWindow/SegmentRowView.swift (stub — replaced in Task 3)
import SwiftUI

struct SegmentRowView: View {
    let segment: MeetingSegment
    let meetingStartedAt: Date
    let onSpeakerRenamed: () -> Void

    var body: some View { EmptyView() }
}
```

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/UI/MainWindow/MeetingDetailView.swift \
        Memgram/UI/MainWindow/SegmentRowView.swift \
        Memgram/Database/MeetingStore.swift
git commit -m "feat(ui): add MeetingDetailView with editable title, summary, and action item checkboxes"
```

---

## Task 3: SegmentRowView + SpeakerRenameView + MeetingStore speaker rename

**Files:**
- Replace: `Memgram/UI/MainWindow/SegmentRowView.swift` (stub → full implementation)
- Create: `Memgram/UI/MainWindow/SpeakerRenameView.swift`
- Modify: `Memgram/Database/MeetingStore.swift`

- [ ] **Step 1: Add speaker rename methods to `MeetingStore.swift`**

Add after `updateTitle`:

```swift
func renameSpeaker(_ oldName: String, to newName: String, inMeeting meetingId: String) throws {
    try db.write { db in
        try db.execute(
            sql: "UPDATE segments SET speaker = ? WHERE meeting_id = ? AND speaker = ?",
            arguments: [newName, meetingId, oldName]
        )
    }
}

func renameSpeakerGlobally(_ oldName: String, to newName: String) throws {
    try db.write { db in
        try db.execute(
            sql: "UPDATE segments SET speaker = ? WHERE speaker = ?",
            arguments: [newName, oldName]
        )
    }
}
```

- [ ] **Step 2: Create `SpeakerRenameView.swift`**

```swift
// Memgram/UI/MainWindow/SpeakerRenameView.swift
import SwiftUI

struct SpeakerRenameView: View {
    let speaker: String
    let meetingId: String
    let onDismiss: () -> Void

    @State private var newName: String
    @State private var applyGlobally = false

    init(speaker: String, meetingId: String, onDismiss: @escaping () -> Void) {
        self.speaker = speaker
        self.meetingId = meetingId
        self.onDismiss = onDismiss
        _newName = State(initialValue: speaker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speaker")
                .font(.headline)
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Toggle("Apply to all meetings", isOn: $applyGlobally)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
                Button("Rename") {
                    rename()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func rename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != speaker else { return }
        if applyGlobally {
            try? MeetingStore.shared.renameSpeakerGlobally(speaker, to: trimmed)
        } else {
            try? MeetingStore.shared.renameSpeaker(speaker, to: trimmed, inMeeting: meetingId)
        }
    }
}
```

- [ ] **Step 3: Replace the stub `SegmentRowView.swift` with the full implementation**

```swift
// Memgram/UI/MainWindow/SegmentRowView.swift
import SwiftUI
import AppKit

struct SegmentRowView: View {
    let segment: MeetingSegment
    let meetingStartedAt: Date
    let onSpeakerRenamed: () -> Void

    @State private var showRename = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Speaker chip
                Button(segment.speaker) { showRename = true }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(speakerColor.opacity(0.15))
                    .foregroundColor(speakerColor)
                    .cornerRadius(4)
                    .font(.caption.bold())
                    .popover(isPresented: $showRename, arrowEdge: .bottom) {
                        SpeakerRenameView(
                            speaker: segment.speaker,
                            meetingId: segment.meetingId,
                            onDismiss: {
                                showRename = false
                                onSpeakerRenamed()
                            }
                        )
                    }

                // Timestamp button — copies absolute time to clipboard
                Button(formatTime(segment.startSeconds)) {
                    copyTimestamp()
                }
                .buttonStyle(.plain)
                .font(.caption2.monospacedDigit())
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .help("Copy timestamp")
            }

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var speakerColor: Color {
        segment.speaker.lowercased() == "you" ? .blue : Color.secondary
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func copyTimestamp() {
        // Compute absolute wall-clock time of this segment
        let absoluteTime = meetingStartedAt.addingTimeInterval(segment.startSeconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss"
        let label = "Meeting — \(formatter.string(from: absoluteTime))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label, forType: .string)
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
git add Memgram/UI/MainWindow/SegmentRowView.swift \
        Memgram/UI/MainWindow/SpeakerRenameView.swift \
        Memgram/Database/MeetingStore.swift
git commit -m "feat(ui): add SegmentRowView with timestamp copy, SpeakerRenameView popover, and speaker rename DB methods"
```

---

## Task 4: SearchView + Cmd+F integration

**Files:**
- Create: `Memgram/UI/MainWindow/SearchView.swift`

`MainWindowView` already wires the sheet and the Cmd+F shortcut (from Task 1). This task only creates the view.

- [ ] **Step 1: Create `SearchView.swift`**

```swift
// Memgram/UI/MainWindow/SearchView.swift
import SwiftUI

struct EnrichedSearchResult: Identifiable {
    var id: String          // segmentId
    var meetingId: String
    var meetingTitle: String
    var meetingDate: Date
    var speaker: String
    var snippet: String
    var timestampSeconds: Double
}

struct SearchView: View {
    var onSelectMeeting: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [EnrichedSearchResult] = []
    @State private var isSearching = false

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search meetings…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onChange(of: query) { _ in performSearch() }
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(16)

            Divider()

            if isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No results for "\(query)"")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { result in
                    SearchResultRow(result: result)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectMeeting?(result.meetingId)
                            dismiss()
                        }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 620, height: 420)
    }

    private func performSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { results = []; return }
        isSearching = true
        Task {
            let raw = (try? await SearchEngine.shared.search(query: trimmed)) ?? []
            let enriched: [EnrichedSearchResult] = raw.compactMap { r in
                guard let meeting = try? MeetingStore.shared.fetchMeeting(r.meetingId) else { return nil }
                return EnrichedSearchResult(
                    id: r.segmentId.isEmpty ? UUID().uuidString : r.segmentId,
                    meetingId: r.meetingId,
                    meetingTitle: meeting.title,
                    meetingDate: meeting.startedAt,
                    speaker: r.speaker,
                    snippet: r.snippet,
                    timestampSeconds: r.timestampSeconds
                )
            }
            await MainActor.run {
                results = enriched
                isSearching = false
            }
        }
    }
}

// MARK: - Result Row

struct SearchResultRow: View {
    let result: EnrichedSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.meetingTitle)
                    .font(.body.bold())
                Spacer()
                Text(DateFormatter.localizedString(
                    from: result.meetingDate,
                    dateStyle: .medium,
                    timeStyle: .short
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }
            if !result.speaker.isEmpty {
                Text(result.speaker)
                    .font(.caption.bold())
                    .foregroundColor(.blue)
            }
            Text(result.snippet)
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run xcodegen to register any new files**

```bash
xcodegen generate
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/UI/MainWindow/SearchView.swift
git commit -m "feat(ui): add SearchView with hybrid search results, wired to Cmd+F in MainWindowView"
```

---

## Spec Coverage Check

| Requirement | Task |
|-------------|------|
| Open from menu bar dedicated button | Task 1 (already in PopoverView from Session 1) |
| NavigationSplitView (list + detail) | Task 1 |
| MeetingListView grouped by date | Task 1 |
| Each row: status dot, title, duration | Task 1 |
| Delete with confirmation | Task 1 |
| Header: editable title, date, duration | Task 2 |
| Summary section | Task 2 |
| Action items checkboxes (UserDefaults) | Task 2 |
| Transcript: speaker chip, timestamp, text | Task 3 |
| Click timestamp → copy to clipboard | Task 3 |
| SpeakerRenameView popover | Task 3 |
| Apply rename to this meeting vs all | Task 3 |
| Renames propagate to all segments | Task 3 |
| SearchView activated by Cmd+F | Task 4 (shortcut in Task 1, view in Task 4) |
| Search results: title, date, speaker, snippet | Task 4 |
| Click result → open meeting | Task 4 |
| Empty state | Task 1 |
