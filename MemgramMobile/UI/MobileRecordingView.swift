import SwiftUI
import EventKit
import OSLog

private let log = Logger.make("RecordingUI")
private let macOfflineWarningTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

@MainActor
struct MobileRecordingView: View {
    @ObservedObject private var recorder = MobileAudioRecorder.shared
    @ObservedObject private var uploader = AudioChunkUploader.shared
    @ObservedObject private var calendarManager = CalendarManager.shared

    @State private var segments: [MeetingSegment] = []
    @State private var errorMessage: String?
    @State private var pendingMacMeetingId: String?
    @State private var lastSegmentArrivedAt: Date?
    @State private var now: Date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if !recorder.isRecording, let event = calendarManager.upcomingEvent {
                    calendarCard(event)
                }

                Spacer()

                elapsedTimeLabel

                recordButton

                if uploader.pendingChunks > 0 {
                    pendingChunksIndicator
                }

                macOfflineBanner

                Spacer()

                if recorder.isRecording || !segments.isEmpty {
                    liveTranscriptSection
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .padding()
            .navigationTitle("Record")
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: .meetingDidUpdate)) { _ in
                refreshSegments()
            }
            .onReceive(macOfflineWarningTimer) { date in
                now = date
            }
        }
    }

    // MARK: - Calendar Card

    private func calendarCard(_ event: EKEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.blue)
                Text("Upcoming Meeting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(event.title ?? "Untitled Event")
                .font(.headline)
            if let start = event.startDate {
                Text(start, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Elapsed Time

    private var elapsedTimeLabel: some View {
        Text(formatElapsed(recorder.elapsedSeconds))
            .font(.system(size: 48, weight: .light, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(recorder.isRecording ? .primary : .secondary)
    }

    // MARK: - Record / Stop Button

    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red.opacity(0.15) : Color.blue.opacity(0.15))
                    .frame(width: 96, height: 96)

                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.red)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(.blue)
                        .frame(width: 64, height: 64)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop Recording" : "Start Recording")
    }

    // MARK: - Pending Chunks

    private var pendingChunksIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("\(uploader.pendingChunks) chunk\(uploader.pendingChunks == 1 ? "" : "s") uploading")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mac Offline Banner

    @ViewBuilder
    private var macOfflineBanner: some View {
        let noRecentSegments = lastSegmentArrivedAt.map { now.timeIntervalSince($0) > 2 * 60 } ?? false
        if recorder.isRecording && noRecentSegments {
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac not available")
                        .font(.subheadline.bold())
                    Text("Transcription and summary will be ready once Memgram is open on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Live Transcript

    private var liveTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(segments, id: \.id) { segment in
                            Text(segment.text)
                                .font(.subheadline)
                                .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 200)
                .onChange(of: segments.count) { _ in
                    if let last = segments.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Actions

    private func toggleRecording() {
        if recorder.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        pendingMacMeetingId = nil
        lastSegmentArrivedAt = Date()
        errorMessage = nil
        segments = []

        // Check for nearby calendar event
        var calendarContext: CalendarContext?
        var title = "Untitled Meeting"

        if let event = calendarManager.upcomingEvent ?? calendarManager.findEvent(around: Date()) {
            calendarContext = calendarManager.context(for: event)
            title = event.title ?? title
        }

        do {
            let meetingId = try uploader.startMeeting(title: title, calendarContext: calendarContext)
            log.info("Meeting started: \(meetingId)")

            recorder.onChunkReady = { fileURL, chunkIndex, offsetSeconds in
                uploader.uploadChunk(fileURL: fileURL, chunkIndex: chunkIndex, offsetSeconds: offsetSeconds)
            }

            try recorder.start()
        } catch {
            errorMessage = error.localizedDescription
            log.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        recorder.stop()
        recorder.onChunkReady = nil

        Task {
            await uploader.finishRecording()
            pendingMacMeetingId = uploader.uploadedMeetingId
            log.info("Recording finished and uploaded")
        }
    }

    private func refreshSegments() {
        guard let meetingId = uploader.currentMeetingId ?? pendingMacMeetingId else { return }
        let fetched = (try? MeetingStore.shared.fetchSegments(forMeeting: meetingId)) ?? []
        if fetched.count > segments.count {
            lastSegmentArrivedAt = Date()
        }
        segments = fetched
    }

    // MARK: - Helpers

    private func formatElapsed(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
