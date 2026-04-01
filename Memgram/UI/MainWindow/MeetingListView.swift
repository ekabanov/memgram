import SwiftUI

extension Meeting: Identifiable {}

struct MeetingListView: View {
    @Binding var selectedMeetingIds: Set<String>
    @State private var meetings: [Meeting] = []
    @State private var meetingToDelete: Meeting?
    @State private var showDeleteAlert = false
    @State private var showBulkDeleteAlert = false
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            SyncStatusHeader()
            List(selection: $selectedMeetingIds) {
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
                                        if selectedMeetingIds.count > 1 && selectedMeetingIds.contains(meeting.id) {
                                            Button("Delete \(selectedMeetingIds.count) Recordings…", role: .destructive) {
                                                showBulkDeleteAlert = true
                                            }
                                        } else {
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
            }
        }
        .navigationTitle("Meetings")
        .toolbar {
            if !selectedMeetingIds.isEmpty {
                ToolbarItem {
                    Button(role: .destructive) {
                        if selectedMeetingIds.count == 1, let id = selectedMeetingIds.first,
                           let meeting = meetings.first(where: { $0.id == id }) {
                            meetingToDelete = meeting
                            showDeleteAlert = true
                        } else {
                            showBulkDeleteAlert = true
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in load() }
        .alert("Delete Recording?", isPresented: $showDeleteAlert, presenting: meetingToDelete) { meeting in
            Button("Delete", role: .destructive) { delete(meeting) }
            Button("Cancel", role: .cancel) {}
        } message: { meeting in
            Text("\"\(meeting.title)\" will be permanently deleted.")
        }
        .alert("Delete \(selectedMeetingIds.count) Recordings?", isPresented: $showBulkDeleteAlert) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
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

    private struct ListSection { let title: String; let meetings: [Meeting] }

    private var groupedSections: [ListSection] {
        let cal = Calendar.current
        let now = Date()
        let todayStart     = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let weekStart      = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

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
            .map { ListSection(title: $0.0, meetings: $0.1) }
    }

    private func load() {
        let all = (try? MeetingStore.shared.fetchAll()) ?? []
        meetings = all.filter { $0.syncStatus != .placeholder }
    }

    private func delete(_ meeting: Meeting) {
        do {
            try MeetingStore.shared.deleteMeeting(meeting.id)
            selectedMeetingIds.remove(meeting.id)
            load()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func deleteSelected() {
        var errors: [String] = []
        for id in selectedMeetingIds {
            do {
                try MeetingStore.shared.deleteMeeting(id)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        selectedMeetingIds = []
        load()
        if !errors.isEmpty {
            deleteError = errors.first
        }
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
                Image(systemName: "icloud.fill")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundStyle(.red)
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
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            case .placeholder:
                EmptyView()
            }
        }
        .font(.caption)
    }
}

private struct SyncStatusHeader: View {
    @ObservedObject private var syncEngine = CloudSyncEngine.shared

    var body: some View {
        if syncEngine.pendingCount > 0 || syncEngine.failedCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                if syncEngine.failedCount > 0 {
                    Label(
                        "\(syncEngine.failedCount) meeting\(syncEngine.failedCount == 1 ? "" : "s") failed to sync",
                        systemImage: "exclamationmark.icloud"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                if syncEngine.pendingCount > 0 {
                    Label(
                        "Syncing \(syncEngine.pendingCount) meeting\(syncEngine.pendingCount == 1 ? "" : "s")…",
                        systemImage: "icloud.and.arrow.up"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

struct MeetingRowView: View {
    let meeting: Meeting
    @ObservedObject private var summaryEngine = SummaryEngine.shared

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
            Spacer()
            if let summary = meeting.summary, !summary.isEmpty {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Summary available")
            }
            CloudSyncIcon(meeting: meeting)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch meeting.status {
        case .recording:                return .red
        case .transcribing, .diarizing: return .orange
        case .done:                     return .green
        case .interrupted:              return .secondary
        case .error:                    return Color.red.opacity(0.5)
        }
    }

    private var subtitle: String {
        let time = DateFormatter.localizedString(from: meeting.startedAt,
                                                  dateStyle: .none, timeStyle: .short)
        switch meeting.status {
        case .recording:    return "\(time) · Recording…"
        case .transcribing: return "\(time) · Transcribing…"
        case .diarizing:    return "\(time) · Identifying speakers…"
        case .interrupted:  return "\(time) · Interrupted"
        case .error:        return "\(time) · Error"
        case .done:
            if summaryEngine.activeMeetingIds.contains(meeting.id) { return "\(time) · Summarising…" }
            guard let dur = meeting.durationSeconds else { return time }
            let mins = Int(dur / 60)
            return mins > 0 ? "\(time) · \(mins)m" : time
        }
    }
}
