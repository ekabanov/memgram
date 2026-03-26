import SwiftUI

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        SegmentRow(segment: segment)
                            .id(segment.id)
                    }
                    // Invisible anchor at the bottom for auto-scroll
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: segments.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment

    private var speakerColor: Color {
        segment.channel == .microphone ? .blue : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(segment.speaker)
                    .font(.caption.bold())
                    .foregroundColor(speakerColor)
                Text(formatTime(segment.startSeconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            Text(segment.text)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
