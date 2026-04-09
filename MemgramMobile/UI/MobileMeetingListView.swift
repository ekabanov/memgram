import SwiftUI
import OSLog

private let log = Logger.make("UI")

struct MobileMeetingListView: View {
    @State private var meetings: [Meeting] = []
    @State private var searchText = ""
    @State private var searchMatchIds: Set<String>?  // nil = no search active

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SyncStatusBanner()
                List {
                    ForEach(displayedMeetings, id: \.key) { date, group in
                        Section(header: Text(sectionTitle(for: date))) {
                            ForEach(group, id: \.id) { meeting in
                                NavigationLink(value: meeting.id) {
                                    MeetingRow(meeting: meeting)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
            .searchable(text: $searchText, prompt: "Search transcripts")
            .onChange(of: searchText) { query in
                updateSearch(query)
            }
            .navigationDestination(for: String.self) { meetingId in
                MobileMeetingDetailView(meetingId: meetingId)
            }
            .refreshable {
                await CloudSyncEngine.shared.fetchNow()
                loadMeetings()
            }
            .onAppear { loadMeetings() }
            .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in
                loadMeetings()
            }
            .overlay {
                if meetings.isEmpty && searchText.isEmpty {
                    ContentUnavailableView(
                        "No Meetings",
                        systemImage: "waveform.badge.mic",
                        description: Text("Meetings recorded on your Mac will appear here.")
                    )
                } else if displayedMeetings.isEmpty && !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    /// Grouped meetings filtered by search. Falls back to title match when FTS has no results.
    private var displayedMeetings: [(key: Date, value: [Meeting])] {
        guard let matchIds = searchMatchIds else { return groupedMeetings }
        let filtered = meetings.filter { matchIds.contains($0.id) || $0.title.localizedCaseInsensitiveContains(searchText) }
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.startedAt) }
        return grouped.sorted { $0.key > $1.key }
    }

    private func updateSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { searchMatchIds = nil; return }
        let results = (try? MeetingStore.shared.searchTranscripts(trimmed)) ?? []
        searchMatchIds = Set(results.map(\.meetingId))
    }

    private var groupedMeetings: [(key: Date, value: [Meeting])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: meetings) { meeting in
            cal.startOfDay(for: meeting.startedAt)
        }
        return grouped.sorted { $0.key > $1.key }
    }

    private func loadMeetings() {
        let all = (try? MeetingStore.shared.fetchAll()) ?? []
        meetings = all.filter { $0.syncStatus != .placeholder }
        log.debug("Loaded \(self.meetings.count) meetings (filtered from \(all.count) total)")
    }

    private func sectionTitle(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}

private struct CloudSyncIcon: View {
    let meeting: Meeting
    @ObservedObject private var syncEngine = CloudSyncEngine.shared
    @State private var pulse = false

    var body: some View {
        Group {
            switch meeting.syncStatus {
            case .synced:
                Image(systemName: "icloud.fill").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.icloud.fill").foregroundStyle(.red)
            case .pendingUpload:
                if syncEngine.uploadingIds.contains(meeting.id) {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .foregroundStyle(.secondary)
                        .opacity(pulse ? 0.4 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                                   value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                } else {
                    Image(systemName: "icloud.and.arrow.up").foregroundStyle(.secondary)
                }
            case .placeholder:
                EmptyView()
            }
        }
        .font(.caption2)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                CloudSyncIcon(meeting: meeting)
                StatusBadge(status: meeting.status)
            }
            HStack(spacing: 6) {
                Text(DateFormatter.localizedString(from: meeting.startedAt,
                                                   dateStyle: .none, timeStyle: .short))
                if let dur = meeting.durationSeconds, dur > 0 {
                    Text("·")
                    Text(formatDuration(dur))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

private struct StatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        switch status {
        case .recording:
            Label("Recording", systemImage: "mic.fill")
                .font(.caption2).foregroundStyle(.red)
        case .transcribing, .diarizing:
            Label("Processing", systemImage: "hourglass")
                .font(.caption2).foregroundStyle(.orange)
        case .interrupted:
            Label("Interrupted", systemImage: "exclamationmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .done:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
        }
    }
}

private struct SyncStatusBanner: View {
    @ObservedObject private var syncEngine = CloudSyncEngine.shared

    var body: some View {
        if syncEngine.pendingCount > 0 || syncEngine.failedCount > 0 {
            VStack(alignment: .leading, spacing: 2) {
                if syncEngine.failedCount > 0 {
                    Label("\(syncEngine.failedCount) meeting\(syncEngine.failedCount == 1 ? "" : "s") failed to sync",
                          systemImage: "exclamationmark.icloud")
                        .font(.caption).foregroundStyle(.red)
                }
                if syncEngine.pendingCount > 0 {
                    Label("Syncing \(syncEngine.pendingCount) meeting\(syncEngine.pendingCount == 1 ? "" : "s")…",
                          systemImage: "icloud.and.arrow.up")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
    }
}
