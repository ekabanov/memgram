import EventKit
import Combine
import OSLog

private let log = Logger.make("Calendar")

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var upcomingEvent: EKEvent?
    @Published private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: "calendarIntegrationEnabled")
    @Published private(set) var availableCalendars: [EKCalendar] = []
    @Published private(set) var selectedCalendarIds: Set<String> = {
        let stored = UserDefaults.standard.stringArray(forKey: "selectedCalendarIds") ?? []
        return stored.isEmpty ? [] : Set(stored)  // empty = all calendars
    }()

    private let store = EKEventStore()
    private var refreshTimer: Timer?

    private init() {
        let status = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = status
        log.info("CalendarManager init — auth: \(status.rawValue)")
    }

    // MARK: - Authorization

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            log.info("Calendar access result: granted=\(granted)")
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                refreshAvailableCalendars()
                refreshUpcomingEvent()
                startMonitoring()
            }
            return granted
        } catch {
            log.warning("Calendar access request failed: \(error)")
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return false
        }
    }

    func setSelectedCalendars(_ ids: Set<String>) {
        selectedCalendarIds = ids
        UserDefaults.standard.set(Array(ids), forKey: "selectedCalendarIds")
        refreshUpcomingEvent()
    }

    func refreshAvailableCalendars() {
        availableCalendars = store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    // MARK: - Enable / Disable

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "calendarIntegrationEnabled")
        if enabled {
            refreshUpcomingEvent()
            startMonitoring()
        } else {
            CalendarNotificationService.shared.cancelAll()
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
        let selectedCalendars: [EKCalendar]? = selectedCalendarIds.isEmpty
            ? nil  // nil = all calendars
            : store.calendars(for: .event).filter { selectedCalendarIds.contains($0.calendarIdentifier) }
        let cutoff = now.addingTimeInterval(-10 * 60)  // ignore events that started >10 min ago
        let predicate = store.predicateForEvents(withStart: cutoff, end: lookahead, calendars: selectedCalendars)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > cutoff }
            .sorted { $0.startDate < $1.startDate }
        log.debug("refreshUpcomingEvent: \(events.count) candidates, upcoming=\(events.first != nil)")
        upcomingEvent = events.first
        if let event = upcomingEvent {
            CalendarNotificationService.shared.scheduleNotification(for: event)
        }
    }

    /// Find a calendar event that overlaps the given time range.
    func findEvent(around date: Date, toleranceMinutes: Double = 10) -> EKEvent? {
        guard isEnabled, authorizationStatus == .fullAccess else { return nil }
        let start = date.addingTimeInterval(-toleranceMinutes * 60)
        let end = date.addingTimeInterval(toleranceMinutes * 60)
        let selectedCalendars: [EKCalendar]? = selectedCalendarIds.isEmpty
            ? nil  // nil = all calendars
            : store.calendars(for: .event).filter { selectedCalendarIds.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selectedCalendars)
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
        refreshAvailableCalendars()
        // Refresh every 60 seconds to catch upcoming events
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUpcomingEvent()
            }
        }
        log.info("Calendar monitoring started")
        // Also listen for calendar changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarChanged),
            name: .EKEventStoreChanged,
            object: store
        )
    }

    func stopMonitoring() {
        log.info("Calendar monitoring stopped")
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
