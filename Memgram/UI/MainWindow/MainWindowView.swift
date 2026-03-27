import SwiftUI

struct MainWindowView: View {
    @State private var selectedMeetingId: String?
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView {
            MeetingListView(selectedMeetingId: $selectedMeetingId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let id = selectedMeetingId {
                MeetingDetailView(meetingId: id, onDelete: { selectedMeetingId = nil })
                    .id(id)
                    .id(id)  // Force recreation on selection change to prevent stale data
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView(onSelectMeeting: { id in
                selectedMeetingId = id
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

