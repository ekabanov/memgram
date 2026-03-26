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
                    if !items.isEmpty {
                        actionItemsSection(items, meetingId: m.id)
                    }
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
                        let mins = Int(dur / 60)
                        let secs = Int(dur.truncatingRemainder(dividingBy: 60))
                        Text("\(mins)m \(secs)s")
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
                        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
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
        guard !trimmed.isEmpty else {
            editableTitle = meeting?.title ?? ""
            isEditingTitle = false
            return
        }
        try? MeetingStore.shared.updateTitle(meetingId, title: trimmed)
        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
        load()
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
