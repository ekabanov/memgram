// Memgram/UI/MainWindow/MeetingDetailView.swift
import SwiftUI
import AppKit
import MarkdownUI

extension MeetingSegment: Identifiable {}

struct MeetingDetailView: View {
    let meetingId: String
    var onDelete: (() -> Void)? = nil

    @State private var meeting: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var editableTitle = ""
    @State private var isEditingTitle = false
    @State private var selectedTab: DetailTab = .summary
    @ObservedObject private var summaryEngine = SummaryEngine.shared
    @State private var selectedSummaryBackend: LLMBackend = LLMProviderStore.shared.selectedBackend
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    @State private var copiedFeedback = false
    @State private var localQuery = ""
    @State private var showLocalSearch = false

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary    = "Summary"
        case transcript = "Transcript"
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

            localSearchBar

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
        .onChange(of: selectedTab) { _ in
            showLocalSearch = false
            localQuery = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in load() }
        .alert("Delete Meeting?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(editableTitle)\" will be permanently deleted.")
        }
        .alert("Could Not Delete", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
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
                    HStack(spacing: 6) {
                        Text(editableTitle.isEmpty ? "Untitled" : editableTitle)
                            .font(.title.bold())
                        Button { isEditingTitle = true } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit title")
                    }
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
            if selectedTab == .transcript {
                Button {
                    withAnimation { showLocalSearch.toggle() }
                    if !showLocalSearch { localQuery = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(showLocalSearch ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Search in transcript")
                .padding(.trailing, 12)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var localSearchBar: some View {
        if showLocalSearch {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search in transcript…", text: $localQuery)
                    .textFieldStyle(.plain)
                if !localQuery.isEmpty {
                    Button { localQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    let count = filteredSegments.count
                    Text("\(count) result\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button { withAnimation { showLocalSearch = false; localQuery = "" } } label: {
                    Text("Done").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            Divider()
        }
    }

    // MARK: - Transcript tab

    @ViewBuilder
    private var transcriptTabContent: some View {
        if segments.isEmpty {
            Text("No transcript available")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else if !localQuery.trimmingCharacters(in: .whitespaces).isEmpty && filteredSegments.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                Text("No results for \"\(localQuery)\"")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredSegments) { segment in
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
        LazyVStack(alignment: .leading, spacing: 16) {
            // Regenerate row — always at the top
            if meeting != nil {
                HStack(spacing: 8) {
                    Picker("", selection: $selectedSummaryBackend) {
                        ForEach(LLMBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .controlSize(.small)

                    Button(isRegenerating ? "Generating…" : (meeting?.summary == nil ? "Generate Summary" : "Regenerate")) {
                        regenerateSummary()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRegenerating)

                    if isRegenerating { ProgressView().controlSize(.small) }
                }
                Divider()
                if let err = summaryEngine.lastError, err.meetingId == meetingId {
                    Label(err.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let summary = meeting?.summary, !summary.isEmpty {
                Markdown(summary)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
            } else if !isRegenerating {
                Text("No summary yet. Click Generate Summary to create one.")
                    .foregroundColor(.secondary)
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
        do {
            try MeetingStore.shared.deleteMeeting(meetingId)
            NotificationCenter.default.post(name: .meetingDidUpdate, object: nil)
            onDelete?()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private var isRegenerating: Bool { summaryEngine.activeMeetingIds.contains(meetingId) }

    private func regenerateSummary() {
        guard !isRegenerating else { return }
        let backend = selectedSummaryBackend
        Task {
            await SummaryEngine.shared.summarize(meetingId: meetingId, overrideBackend: backend)
            await MainActor.run {
                load()
            }
        }
    }

    // MARK: - Helpers

    private var filteredSegments: [MeetingSegment] {
        let q = localQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return segments }
        return segments.filter {
            $0.text.localizedCaseInsensitiveContains(q) ||
            $0.speaker.localizedCaseInsensitiveContains(q)
        }
    }

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

