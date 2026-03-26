// Memgram/UI/MainWindow/SpeakerRenameView.swift
import SwiftUI

struct SpeakerRenameView: View {
    let speaker: String
    let meetingId: String
    let onDismiss: () -> Void

    @State private var newName: String
    @State private var applyGlobally = false

    init(speaker: String, meetingId: String, onDismiss: @escaping () -> Void) {
        self.speaker = speaker
        self.meetingId = meetingId
        self.onDismiss = onDismiss
        _newName = State(initialValue: speaker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speaker")
                .font(.headline)
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Toggle("Apply to all meetings", isOn: $applyGlobally)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
                Button("Rename") {
                    rename()
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func rename() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != speaker else { return }
        if applyGlobally {
            try? MeetingStore.shared.renameSpeakerGlobally(speaker, to: trimmed)
        } else {
            try? MeetingStore.shared.renameSpeaker(speaker, to: trimmed, inMeeting: meetingId)
        }
    }
}
