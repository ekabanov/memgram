import Foundation
import OSLog
#if os(macOS)
import AVFoundation
#endif
import EventKit

struct BugReportPayload: Codable {
    let schemaVersion: Int
    let appVersion: String
    let macosVersion: String
    let hardwareModel: String
    let physicalMemoryGB: Int
    let whisperModel: String?
    let llmBackend: String?
    let recordingState: String?
    let calendarPermission: String
    let microphonePermission: String?
    let icloudSyncEnabled: Bool
    let meetingsMetadata: [MeetingMeta]
    let logs: [LogEntry]
    let crashLog: String?

    struct MeetingMeta: Codable {
        let durationSeconds: Double?
        let transcriptLengthChars: Int
        let segmentCount: Int
        let hasSummary: Bool
        let hasCalendarContext: Bool
        let speakersCount: Int
    }

    struct LogEntry: Codable {
        let date: String      // ISO8601
        let category: String
        let level: String
        let message: String
    }
}

final class BugReportPayloadBuilder {

    static func build() async -> BugReportPayload {
        let processInfo = ProcessInfo.processInfo
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        let osVersion = processInfo.operatingSystemVersionString
        let ramGB = Int(processInfo.physicalMemory / (1024 * 1024 * 1024))

        let hardwareModel = Self.hardwareModelIdentifier()

        // Capture main-actor state on the main actor before going off-thread
        #if os(macOS)
        let (whisperModel, llmBackend, recordingState, micPerm): (String?, String?, String?, String?) =
            await MainActor.run {
                (WhisperModelManager.shared.selectedModel.whisperKitName,
                 LLMProviderStore.shared.selectedBackend.rawValue,
                 RecordingSession.shared.isRecording ? "recording" : "idle",
                 Self.microphonePermissionString())
            }
        #else
        let whisperModel: String? = nil
        let llmBackend: String?   = nil
        let recordingState: String? = nil
        let micPerm: String?      = nil
        #endif

        let calendarPerm = Self.calendarPermissionString()
        let icloudEnabled = true

        // Run expensive work off the main thread
        let meetingsMeta = await Self.buildMeetingsMeta()
        let (logs, crashLog) = await Task.detached(priority: .userInitiated) {
            (await Self.collectLogs(), Self.mostRecentCrashLog())
        }.value

        return BugReportPayload(
            schemaVersion: 1,
            appVersion: "\(version) (\(build))",
            macosVersion: osVersion,
            hardwareModel: hardwareModel,
            physicalMemoryGB: ramGB,
            whisperModel: whisperModel,
            llmBackend: llmBackend,
            recordingState: recordingState,
            calendarPermission: calendarPerm,
            microphonePermission: micPerm,
            icloudSyncEnabled: icloudEnabled,
            meetingsMetadata: meetingsMeta,
            logs: logs,
            crashLog: crashLog
        )
    }

    // MARK: - Helpers

    private static func hardwareModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private static func calendarPermissionString() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:    return "fullAccess"
        case .writeOnly:     return "writeOnly"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default:    return "unknown"
        }
    }

    #if os(macOS)
    private static func microphonePermissionString() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return "granted"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default:    return "unknown"
        }
    }
    #endif

    private static func buildMeetingsMeta() async -> [BugReportPayload.MeetingMeta] {
        let meetings = (try? MeetingStore.shared.fetchAll()) ?? []
        return meetings.prefix(20).compactMap { meeting -> BugReportPayload.MeetingMeta? in
            let segCount = (try? MeetingStore.shared.fetchSegments(forMeeting: meeting.id))?.count ?? 0
            return BugReportPayload.MeetingMeta(
                durationSeconds: meeting.durationSeconds,
                transcriptLengthChars: meeting.rawTranscript?.count ?? 0,
                segmentCount: segCount,
                hasSummary: meeting.summary != nil,
                hasCalendarContext: meeting.calendarContext != nil,
                speakersCount: 0  // speaker table not fetched here to keep this lightweight
            )
        }
    }

    private static func collectLogs() async -> [BugReportPayload.LogEntry] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let since = Date().addingTimeInterval(-1800)  // last 30 minutes
        let position = store.position(date: since)
        let predicate = NSPredicate(format: "subsystem == %@", "com.memgram.app")
        guard let entries = try? store.getEntries(at: position, matching: predicate) else { return [] }

        let formatter = ISO8601DateFormatter()
        var result: [BugReportPayload.LogEntry] = []
        for entry in entries.prefix(100_000) {
            guard let logEntry = entry as? OSLogEntryLog else { continue }
            result.append(BugReportPayload.LogEntry(
                date: formatter.string(from: logEntry.date),
                category: logEntry.category,
                level: levelString(logEntry.level),
                message: logEntry.composedMessage
            ))
        }
        return result
    }

    private static func levelString(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:   return "debug"
        case .info:    return "info"
        case .notice:  return "notice"
        case .error:   return "error"
        case .fault:   return "fault"
        default:       return "default"
        }
    }

    private static func mostRecentCrashLog() -> String? {
        let diagDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diagDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        let recent = files
            .filter { $0.lastPathComponent.hasPrefix("Memgram") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      date > sevenDaysAgo else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .first?.0

        guard let recent else { return nil }
        guard let text = try? String(contentsOf: recent, encoding: .utf8) else { return nil }
        // Cap at 50 KB to keep the payload size reasonable
        return text.count > 50_000 ? String(text.prefix(50_000)) + "\n[truncated]" : text
    }
}
