// Memgram/UI/MainWindow/SegmentRowView.swift
import SwiftUI
import AppKit

struct SegmentRowView: View {
    let segment: MeetingSegment
    let meetingStartedAt: Date
    let onSpeakerRenamed: () -> Void

    @State private var showRename = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Speaker chip — opens rename popover
                Button(segment.speaker) { showRename = true }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(speakerColor.opacity(0.15))
                    .foregroundColor(speakerColor)
                    .cornerRadius(4)
                    .font(.caption.bold())
                    .popover(isPresented: $showRename, arrowEdge: .bottom) {
                        SpeakerRenameView(
                            speaker: segment.speaker,
                            meetingId: segment.meetingId,
                            onDismiss: {
                                showRename = false
                                onSpeakerRenamed()
                            }
                        )
                    }

                // Timestamp — copies absolute wall-clock time to clipboard
                Button(formatTime(segment.startSeconds)) {
                    copyTimestamp()
                }
                .buttonStyle(.plain)
                .font(.caption2.monospacedDigit())
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .help("Copy timestamp")
            }

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var speakerColor: Color {
        segment.speaker.lowercased() == "you" ? .blue : Color.secondary
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func copyTimestamp() {
        let absoluteTime = meetingStartedAt.addingTimeInterval(segment.startSeconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm:ss"
        let label = "Meeting — \(formatter.string(from: absoluteTime))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(label, forType: .string)
    }
}
