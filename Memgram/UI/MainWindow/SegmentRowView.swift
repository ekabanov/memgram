// Memgram/UI/MainWindow/SegmentRowView.swift
import SwiftUI
import AppKit

struct SegmentRowView: View {
    let segment: MeetingSegment
    let meetingStartedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Timestamp — copies absolute wall-clock time to clipboard
            Button(formatTime(segment.startSeconds)) {
                copyTimestamp()
            }
            .buttonStyle(.plain)
            .font(.caption2.monospacedDigit())
            .foregroundColor(Color(NSColor.tertiaryLabelColor))
            .help("Copy timestamp")

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
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
