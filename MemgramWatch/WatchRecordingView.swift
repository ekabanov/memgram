import SwiftUI
import os

private let log = Logger(subsystem: "com.memgram.app", category: "WatchUI")

struct WatchRecordingView: View {
    @StateObject private var recorder = WatchAudioRecorder()
    @ObservedObject private var session = WatchSessionManager.shared
    @State private var recordingStartedAt: Date?

    var body: some View {
        VStack(spacing: 12) {
            if let title = session.calendarEventTitle, !recorder.isRecording {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if recorder.isRecording {
                Text(formatElapsed(recorder.elapsedSeconds))
                    .font(.system(.title, design: .monospaced))
                    .foregroundStyle(.red)
            }

            Button {
                if recorder.isRecording { stopRecording() }
                else { startRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRecording ? .red : .blue)
                        .frame(width: 60, height: 60)
                    if recorder.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white)
                            .frame(width: 20, height: 20)
                    } else {
                        Circle()
                            .fill(.white)
                            .frame(width: 22, height: 22)
                    }
                }
            }
            .buttonStyle(.plain)

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            session.requestCalendarContext()
        }
    }

    private var statusText: String {
        if recorder.isRecording { return "Recording" }
        switch session.transferStatus {
        case .idle: return "Tap to record"
        case .transferring: return "Sending to iPhone…"
        case .done: return "Sent to iPhone"
        case .failed: return "Transfer failed"
        }
    }

    private func startRecording() {
        recorder.start()
        recordingStartedAt = Date()
        session.transferStatus = .idle
    }

    private func stopRecording() {
        guard let fileURL = recorder.stop() else { return }
        let startedAt = recordingStartedAt ?? Date()

        var calendarJSON: String? = nil
        if let title = session.calendarEventTitle {
            let ctx = CalendarContextLite(eventTitle: title, startDate: startedAt)
            calendarJSON = ctx.toJSON()
        }

        session.transferRecording(fileURL: fileURL, startedAt: startedAt, calendarContextJSON: calendarJSON)
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct CalendarContextLite: Codable {
    let eventTitle: String
    let startDate: Date

    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
