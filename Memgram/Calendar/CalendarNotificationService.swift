import UserNotifications
import EventKit

final class CalendarNotificationService {
    static let shared = CalendarNotificationService()

    private let center = UNUserNotificationCenter.current()
    /// Category identifier for meeting start notifications.
    static let categoryId = "MEETING_START"
    /// Action identifier for the "Start Recording" button in the notification.
    static let startRecordingActionId = "START_RECORDING"

    private init() {}

    func setup() {
        let startAction = UNNotificationAction(
            identifier: Self.startRecordingActionId,
            title: "Start Recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [startAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])
    }

    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Schedule a notification 1 minute before the given event starts.
    func scheduleNotification(for event: EKEvent) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting Starting"
        content.body = "\(event.title ?? "Meeting") starts in 1 minute. Tap to record."
        content.categoryIdentifier = Self.categoryId
        content.userInfo = ["eventIdentifier": event.eventIdentifier ?? ""]
        content.sound = .default

        let fireDate = event.startDate.addingTimeInterval(-60)
        guard fireDate > Date() else { return }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "meeting-\(event.eventIdentifier ?? UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    /// Cancel all pending meeting notifications.
    func cancelAll() {
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests
                .filter { $0.identifier.hasPrefix("meeting-") }
                .map(\.identifier)
            self?.center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
