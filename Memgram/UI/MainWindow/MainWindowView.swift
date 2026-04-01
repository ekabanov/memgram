import SwiftUI

struct MainWindowView: View {
    @State private var selectedMeetingIds: Set<String> = []
    @State private var showSearch = false

    private var focusedId: String? { selectedMeetingIds.count == 1 ? selectedMeetingIds.first : nil }

    var body: some View {
        NavigationSplitView {
            MeetingListView(selectedMeetingIds: $selectedMeetingIds)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let id = focusedId {
                MeetingDetailView(meetingId: id, onDelete: { selectedMeetingIds = [] })
                    .id(id)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView(onSelectMeeting: { id in
                selectedMeetingIds = [id]
            })
        }
        .background {
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

