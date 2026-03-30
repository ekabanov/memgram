import SwiftUI
import OSLog

private let log = Logger.make("UI")

struct MobileMeetingListView: View {
    @State private var meetings: [Meeting] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedMeetings, id: \.key) { date, group in
                    Section(header: Text(sectionTitle(for: date))) {
                        ForEach(group, id: \.id) { meeting in
                            NavigationLink(value: meeting.id) {
                                MeetingRow(meeting: meeting)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
            .navigationDestination(for: String.self) { meetingId in
                MobileMeetingDetailView(meetingId: meetingId)
            }
            .refreshable { loadMeetings() }
            .onAppear { loadMeetings() }
            .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in
                loadMeetings()
            }
            .overlay {
                if meetings.isEmpty {
                    ContentUnavailableView(
                        "No Meetings",
                        systemImage: "waveform.badge.mic",
                        description: Text("Meetings recorded on your Mac will appear here.")
                    )
                }
            }
        }
    }

    private var groupedMeetings: [(key: Date, value: [Meeting])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: meetings) { meeting in
            cal.startOfDay(for: meeting.startedAt)
        }
        return grouped.sorted { $0.key > $1.key }
    }

    private func loadMeetings() {
        meetings = (try? MeetingStore.shared.fetchAll()) ?? []
        log.debug("Loaded \(self.meetings.count) meetings")
    }

    private func sectionTitle(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
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
                StatusBadge(status: meeting.status)
            }
            HStack(spacing: 6) {
                Text(DateFormatter.localizedString(from: meeting.startedAt, dateStyle: .none, timeStyle: .short))
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
                .font(.caption2)
                .foregroundStyle(.red)
        case .transcribing:
            Label("Processing", systemImage: "hourglass")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .done:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}
