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
            Text("\"\(meeting.title)\" will be permanently deleted.")
        }
    }

    private struct ListSection { let title: String; let meetings: [Meeting] }

    private var groupedSections: [ListSection] {
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
            .map { ListSection(title: $0.0, meetings: $0.1) }
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
