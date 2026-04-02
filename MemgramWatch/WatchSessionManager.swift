import WatchConnectivity
import Foundation
import os

private let log = Logger.make("WatchSession")

final class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    @Published var calendarEventTitle: String?
    @Published var transferStatus: TransferStatus = .idle

    enum TransferStatus: String {
        case idle = "Ready"
        case transferring = "Sending to iPhone…"
        case done = "Sent"
        case failed = "Transfer failed"
    }

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
            log.info("WCSession activated")
        }
    }

    func requestCalendarContext() {
        guard WCSession.default.isReachable else {
            log.info("iPhone not reachable — recording without calendar context")
            return
        }
        WCSession.default.sendMessage(["requestCalendarContext": true], replyHandler: { reply in
            if let title = reply["eventTitle"] as? String {
                Task { @MainActor in
                    self.calendarEventTitle = title
                    log.info("Calendar context received: \(title)")
                }
            }
        }, errorHandler: { error in
            log.warning("Calendar context request failed: \(error.localizedDescription)")
        })
    }

    func transferRecording(fileURL: URL, startedAt: Date, calendarContextJSON: String?) {
        var metadata: [String: Any] = [
            "startedAt": startedAt.timeIntervalSince1970,
            "source": "watch"
        ]
        if let json = calendarContextJSON {
            metadata["calendarContext"] = json
        }
        transferStatus = .transferring
        WCSession.default.transferFile(fileURL, metadata: metadata)
        log.info("File transfer queued: \(fileURL.lastPathComponent)")
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        log.info("WCSession activation: \(activationState.rawValue), error: \(error?.localizedDescription ?? "none")")
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        Task { @MainActor in
            if let error {
                log.error("File transfer failed: \(error.localizedDescription)")
                self.transferStatus = .failed
            } else {
                log.info("File transfer complete")
                self.transferStatus = .done
                try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
            }
        }
    }
}
