import SwiftUI
import MarkdownUI
import OSLog

private let log = Logger.make("UI")

private let detailProgressTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

struct MobileMeetingDetailView: View {
    let meetingId: String

    @State private var meeting: Meeting?
    @State private var segments: [MeetingSegment] = []
    @State private var selectedTab: DetailTab = .summary
    @State private var searchText = ""
    @State private var lastSegmentCount: Int = 0
    @State private var lastSegmentArrivedAt: Date?
    @State private var now: Date = Date()
    @State private var viewAppearedAt: Date = Date()
    @State private var isExportingPDF = false
    @State private var exportedPDF: ExportedPDF?

    private var recordingFinishedAt: Date {
        (UserDefaults.standard.object(forKey: "uploadFinishedAt_\(meetingId)") as? Date) ?? viewAppearedAt
    }

    enum DetailTab: String, CaseIterable {
        case summary = "Summary"
        case transcript = "Transcript"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case .summary:
                summaryContent
            case .transcript:
                transcriptContent
            }
        }
        .navigationTitle(meeting?.title ?? "Meeting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let meeting, let summary = meeting.summary, !summary.isEmpty {
                    if isExportingPDF {
                        ProgressView()
                    } else {
                        Button {
                            exportPDF()
                        } label: {
                            Label("Export PDF", systemImage: "doc.richtext")
                        }
                    }
                    ShareLink(item: summary,
                              subject: Text(meeting.title),
                              message: Text("Meeting notes from Memgram"))
                }
            }
        }
        .sheet(item: $exportedPDF) { pdf in
            ActivityShareSheet(items: [pdf.url])
        }
        .onAppear {
            viewAppearedAt = Date()
            loadMeeting()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in
            loadMeeting()
        }
        .onReceive(detailProgressTimer) { date in
            now = date
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = meeting?.summary, !summary.isEmpty {
            ScrollView {
                Markdown(summary)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .padding()
            }
        } else if meeting?.status == .transcribing || meeting?.status == .recording {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                if shouldShowMacOfflineWarning {
                    Text("Mac not available")
                        .font(.headline)
                    Text("Transcription and summary will be ready once Memgram is open on your Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Processing on Mac…")
                        .font(.headline)
                    Text("Transcript and summary will appear here shortly.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No summary yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if segments.isEmpty {
            Text("No transcript available.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                let displayed = searchText.isEmpty
                    ? segments
                    : segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
                ForEach(displayed, id: \.id) { seg in
                    SegmentRow(segment: seg)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search transcript")
        }
    }

    private func exportPDF() {
        guard let meeting else { return }
        isExportingPDF = true
        Task { @MainActor in
            defer { isExportingPDF = false }
            do {
                let data = try MobilePDFExporter.export(meeting: meeting)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(MobilePDFExporter.suggestedFilename(for: meeting))
                try data.write(to: url, options: .atomic)
                exportedPDF = ExportedPDF(url: url)
            } catch {
                log.error("PDF export failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadMeeting() {
        meeting = try? MeetingStore.shared.fetchMeeting(meetingId)
        let fetched = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        if fetched.count > lastSegmentCount {
            lastSegmentCount = fetched.count
            lastSegmentArrivedAt = Date()
        }
        segments = fetched
    }

    private var shouldShowMacOfflineWarning: Bool {
        guard meeting != nil else { return false }
        let gracePeriodElapsed = now.timeIntervalSince(recordingFinishedAt) > 10 * 60
        let noRecentSegments: Bool
        if let lastArrival = lastSegmentArrivedAt {
            noRecentSegments = now.timeIntervalSince(lastArrival) > 2 * 60
        } else {
            noRecentSegments = true
        }
        return gracePeriodElapsed && noRecentSegments
    }
}

private struct ExportedPDF: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SegmentRow: View {
    let segment: MeetingSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatTimestamp(segment.startSeconds))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(segment.text)
                .font(.body)
        }
        .padding(.vertical, 2)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
