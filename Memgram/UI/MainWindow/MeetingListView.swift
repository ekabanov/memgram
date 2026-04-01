import SwiftUI

extension Meeting: Identifiable {}

struct MeetingListView: View {
    @Binding var selectedMeetingId: String?
    @State private var meetings: [Meeting] = []
    @State private var meetingToDelete: Meeting?
    @State private var showDeleteAlert = false
    @State private var deleteError: String?

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
        .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in load() }
        .alert("Delete Recording?", isPresented: $showDeleteAlert, presenting: meetingToDelete) { meeting in
            Button("Delete", role: .destructive) { delete(meeting) }
            Button("Cancel", role: .cancel) {}
        } message: { meeting in
            Text("\"\(meeting.title)\" will be permanently deleted.")
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
        // Hide meetings with no transcript and no summary — empty recordings.
        // Keep meetings whose rawTranscript is nil (interrupted/recovered — may have segments).
        meetings = all.filter { m in
            let hasTranscript = m.rawTranscript.map { !$0.isEmpty } ?? false
            let hasSummary    = m.summary.map { !$0.isEmpty } ?? false
            let isInterrupted = m.rawTranscript == nil
            return hasTranscript || hasSummary || isInterrupted || m.status == .recording || m.status == .transcribing
        }
    }

    private func delete(_ meeting: Meeting) {
        do {
            try MeetingStore.shared.deleteMeeting(meeting.id)
            if selectedMeetingId == meeting.id { selectedMeetingId = nil }
            load()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

struct MeetingRowView: View {
    let meeting: Meeting
    @ObservedObject private var summaryEngine = SummaryEngine.shared

    var body: some View {
        HStack(spacing: 8) {
            if summaryEngine.activeMeetingIds.contains(meeting.id) {
                ProgressView().controlSize(.mini).frame(width: 8, height: 8)
            } else {
                Circle().fill(statusColor).frame(width: 8, height: 8)
            }
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
                    .foregroundColor(.secondary)
                    .help("Summary available")
            }
        }
        .padding(.vertical, 2)
    }

    private var isInterrupted: Bool {
        meeting.rawTranscript == nil && meeting.status == .done
    }

    private var statusColor: Color {
        if isInterrupted { return .secondary }
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
        if isInterrupted { return "\(time) · Interrupted" }
        guard let dur = meeting.durationSeconds else { return time }
        let mins = Int(dur / 60)
        return mins > 0 ? "\(time) · \(mins)m" : time
    }
}
