import EventKit
import Combine

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var upcomingEvent: EKEvent?
    @Published private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: "calendarIntegrationEnabled")

    private let store = EKEventStore()
    private var refreshTimer: Timer?

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Authorization

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                refreshUpcomingEvent()
                startMonitoring()
            }
            return granted
        } catch {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return false
        }
    }

    // MARK: - Enable / Disable

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "calendarIntegrationEnabled")
        if enabled {
            refreshUpcomingEvent()
            startMonitoring()
        } else {
            stopMonitoring()
            upcomingEvent = nil
        }
    }

    // MARK: - Event Fetching

    /// Fetch the next non-all-day event starting within the next 15 minutes.
    func refreshUpcomingEvent() {
        guard isEnabled, authorizationStatus == .fullAccess else {
            upcomingEvent = nil
            return
        }
        let now = Date()
        let lookahead = now.addingTimeInterval(15 * 60)  // 15 minutes
        let predicate = store.predicateForEvents(withStart: now, end: lookahead, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
        upcomingEvent = events.first
    }

    /// Find a calendar event that overlaps the given time range.
    func findEvent(around date: Date, toleranceMinutes: Double = 10) -> EKEvent? {
        guard authorizationStatus == .fullAccess else { return nil }
        let start = date.addingTimeInterval(-toleranceMinutes * 60)
        let end = date.addingTimeInterval(toleranceMinutes * 60)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
        return events.first
    }

    /// Build a CalendarContext from an EKEvent.
    func context(for event: EKEvent) -> CalendarContext {
        let attendeeNames = (event.attendees ?? []).compactMap { $0.name }
        return CalendarContext(
            eventTitle: event.title ?? "Untitled Event",
            notes: event.notes,
            attendees: attendeeNames,
            organizer: event.organizer?.name,
            startDate: event.startDate,
            endDate: event.endDate
        )
    }

    // MARK: - Monitoring

    func startMonitoring() {
        stopMonitoring()
        guard isEnabled else { return }
        // Refresh every 60 seconds to catch upcoming events
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUpcomingEvent()
            }
        }
        // Also listen for calendar changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarChanged),
            name: .EKEventStoreChanged,
            object: store
        )
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: store)
    }

    @objc private func calendarChanged(_ notification: Notification) {
        Task { @MainActor in
            self.refreshUpcomingEvent()
        }
    }
}
