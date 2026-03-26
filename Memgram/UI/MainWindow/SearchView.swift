// Memgram/UI/MainWindow/SearchView.swift
import SwiftUI

struct EnrichedSearchResult: Identifiable {
    var id: String          // segmentId (or UUID string if empty)
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

            Group {
                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No results for \"\(query)\"")
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
