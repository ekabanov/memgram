// Memgram/UI/MainWindow/MeetingDetailView.swift
import SwiftUI
import AppKit

extension MeetingSegment: Identifiable {}

struct MeetingDetailView: View {
    let meetingId: String
    var onDelete: (() -> Void)? = nil

    @State private var meeting: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var editableTitle = ""
    @State private var isEditingTitle = false
    @State private var selectedTab: DetailTab = .summary
    @State private var isRegenerating = false
    @State private var selectedSummaryBackend: LLMBackend = LLMProviderStore.shared.selectedBackend
    @State private var showDeleteConfirm = false
    @State private var copiedFeedback = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case summary    = "Summary"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)

            // Tab bar + actions row
            tabBarRow

            Divider()

            // Tab content
            ScrollView {
                Group {
                    if selectedTab == .transcript {
                        transcriptTabContent
                    } else {
                        summaryTabContent
                    }
                }
                .padding(24)
            }
        }
        .onAppear { load() }
        .onChange(of: meetingId) { _ in
            selectedTab = .summary
            load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in load() }
        .alert("Delete Meeting?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(editableTitle)\" will be permanently deleted.")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
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
                    HStack(spacing: 6) {
                        Text(DateFormatter.localizedString(from: m.startedAt,
                                                           dateStyle: .long, timeStyle: .short))
                        if let dur = m.durationSeconds, dur > 0 {
                            Text("·")
                            Text(formatDuration(dur))
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            }
            Spacer()
            // Actions: copy + more menu
            HStack(spacing: 4) {
                Button {
                    copyCurrentTab()
                    giveCopyFeedback()
                } label: {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .foregroundColor(copiedFeedback ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(selectedTab == .transcript ? "Copy transcript" : "Copy summary")

                Menu {
                    Button {
                        copyTranscriptText()
                        giveCopyFeedback()
                    } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }

                    Button {
                        copySummaryText()
                        giveCopyFeedback()
                    } label: { Label("Copy Summary", systemImage: "sparkles") }
                    .disabled(meeting?.summary == nil)

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: { Label("Delete Meeting", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("More actions")
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Tab bar

    private var tabBarRow: some View {
        HStack {
            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(.leading, 24)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Transcript tab

    @ViewBuilder
    private var transcriptTabContent: some View {
        if segments.isEmpty {
            Text("No transcript available")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(segments) { segment in
                    SegmentRowView(
                        segment: segment,
                        meetingStartedAt: meeting?.startedAt ?? Date(),
                        onSpeakerRenamed: {
                            load()
                            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
                        }
                    )
                    Divider()
                }
            }
        }
    }

    // MARK: - Summary tab

    @ViewBuilder
    private var summaryTabContent: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if let m = meeting, let summary = m.summary, !summary.isEmpty {
                let parsed = parseSummary(summary)
                ForEach(Array(parsed.enumerated()), id: \.offset) { _, section in
                    styledSummarySection(section)
                }
                // Action items inline in summary if present
                let items = actionItems(from: m)
                if !items.isEmpty {
                    actionItemsSection(items, meetingId: m.id)
                }
            } else {
                Text("No summary yet.")
                    .foregroundColor(.secondary)
            }

            // Regenerate row
            if let m = meeting, let transcript = m.rawTranscript, !transcript.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    Picker("", selection: $selectedSummaryBackend) {
                        ForEach(LLMBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .controlSize(.small)

                    Button(isRegenerating ? "Generating…" : (m.summary == nil ? "Generate Summary" : "Regenerate")) {
                        regenerateSummary()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRegenerating)

                    if isRegenerating {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func copyCurrentTab() {
        if selectedTab == .transcript { copyTranscriptText() }
        else { copySummaryText() }
    }

    private func copyTranscriptText() {
        let lines: [String] = segments.map { seg in
            let ts = formatTimestamp(seg.startSeconds)
            return "\(seg.speaker) [\(ts)]: \(seg.text)"
        }
        let pasteStr = lines.isEmpty ? "(no transcript)" : lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasteStr, forType: NSPasteboard.PasteboardType.string)
    }

    private func copySummaryText() {
        let pasteStr = meeting?.summary ?? "(no summary)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasteStr, forType: NSPasteboard.PasteboardType.string)
    }

    private func giveCopyFeedback() {
        withAnimation { copiedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedFeedback = false }
        }
    }

    private func performDelete() {
        try? MeetingStore.shared.deleteMeeting(meetingId)
        NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
        onDelete?()
    }

    private func regenerateSummary() {
        guard !isRegenerating else { return }
        isRegenerating = true
        let backend = selectedSummaryBackend
        Task {
            await SummaryEngine.shared.summarize(meetingId: meetingId, overrideBackend: backend)
            await MainActor.run {
                isRegenerating = false
                load()
            }
        }
    }

    // MARK: - Summary parsing & display

    private struct SummarySection {
        let title: String
        let content: String
    }

    private func parseSummary(_ raw: String) -> [SummarySection] {
        let headers = ["PARTICIPANTS", "TOPICS DISCUSSED", "SUMMARY", "KEY DECISIONS", "ACTION ITEMS"]
        var sections: [SummarySection] = []
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        for (i, header) in headers.enumerated() {
            guard let headerRange = text.range(of: header, options: .caseInsensitive) else { continue }
            let contentStart = headerRange.upperBound
            let contentEnd: String.Index
            let nextHeaders = headers.dropFirst(i + 1)
            if let nextHeader = nextHeaders.first(where: {
                text.range(of: $0, options: .caseInsensitive, range: contentStart..<text.endIndex) != nil
            }), let nextRange = text.range(of: nextHeader, options: .caseInsensitive,
                                           range: contentStart..<text.endIndex) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = text.endIndex
            }
            let content = String(text[contentStart..<contentEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty && content.lowercased() != "none" {
                sections.append(SummarySection(title: header, content: content))
            }
        }
        if sections.isEmpty && !text.isEmpty {
            sections.append(SummarySection(title: "SUMMARY", content: text))
        }
        return sections
    }

    private func styledSummarySection(_ section: SummarySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: sectionIcon(section.title))
                    .foregroundColor(sectionColor(section.title))
                    .font(.subheadline)
                Text(sectionDisplayTitle(section.title))
                    .font(.headline)
            }
            Text(section.content)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionIcon(_ title: String) -> String {
        switch title.uppercased() {
        case "PARTICIPANTS":     return "person.2"
        case "TOPICS DISCUSSED": return "text.alignleft"
        case "SUMMARY":          return "text.alignleft"
        case "KEY DECISIONS":    return "checkmark.seal"
        case "ACTION ITEMS":     return "checklist"
        default:                 return "doc.text"
        }
    }

    private func sectionColor(_ title: String) -> Color {
        switch title.uppercased() {
        case "PARTICIPANTS":     return .purple
        case "TOPICS DISCUSSED": return .blue
        case "SUMMARY":          return .blue
        case "KEY DECISIONS":    return .orange
        case "ACTION ITEMS":     return .green
        default:                 return .secondary
        }
    }

    private func sectionDisplayTitle(_ title: String) -> String {
        switch title.uppercased() {
        case "PARTICIPANTS":     return "Participants"
        case "TOPICS DISCUSSED": return "Topics Discussed"
        case "SUMMARY":          return "Summary"
        case "KEY DECISIONS":    return "Key Decisions"
        case "ACTION ITEMS":     return "Action Items"
        default:                 return title.capitalized
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

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds / 60), s = Int(seconds.truncatingRemainder(dividingBy: 60))
        return "\(m)m \(s)s"
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

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
        self.text = text; self.meetingId = meetingId; self.index = index
        _isChecked = State(initialValue:
            UserDefaults.standard.bool(forKey: "actionChecked_\(meetingId)_\(index)"))
    }

    var body: some View {
        Toggle(isOn: $isChecked) {
            Text(text).strikethrough(isChecked).foregroundColor(isChecked ? .secondary : .primary)
        }
        .toggleStyle(.checkbox)
        .onChange(of: isChecked) { newValue in
            UserDefaults.standard.set(newValue, forKey: "actionChecked_\(meetingId)_\(index)")
        }
    }
}
