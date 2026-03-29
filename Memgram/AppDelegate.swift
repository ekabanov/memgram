import AppKit
import SwiftUI
import Combine
import AVFoundation
import EventKit
import UserNotifications
import OSLog

private let appLog = Logger.make("App")

enum RecordingState {
    case idle
    case upcoming   // calendar event starting within 15 min
    case recording
    case processing
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var pulseTimer: Timer?

    var recordingState: RecordingState = .idle {
        didSet { updateStatusIcon() }
    }

    private var sessionCancellable: AnyCancellable?
    private var calendarCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog.info("App launched — v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?", privacy: .public) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", privacy: .public))")
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        showOnboardingIfNeeded()
        RecordingSession.shared.loadInterruptedMeetings()
        appLog.info("Interrupted meetings on launch: \(RecordingSession.shared.interruptedMeetings.count)")
        SummaryEngine.shared.cleanExistingSummaries()

        // Pre-download models in the background so first recording starts instantly.
        RecordingSession.shared.preloadWhisperModel()
        #if canImport(MLXLLM)
        if #available(macOS 14, *), LLMProviderStore.shared.selectedBackend == .qwen {
            QwenLocalProvider.shared.preload()
        }
        #endif

        if #available(macOS 14.0, *) {
            CloudSyncEngine.shared.start()
            appLog.info("CloudSync started")
        }

        UNUserNotificationCenter.current().delegate = self

        // Calendar integration
        CalendarNotificationService.shared.setup()
        if CalendarManager.shared.isEnabled {
            Task {
                _ = await CalendarManager.shared.requestAccess()
                CalendarManager.shared.startMonitoring()
                _ = await CalendarNotificationService.shared.requestPermission()
            }
        }
        appLog.info("Calendar integration enabled: \(CalendarManager.shared.isEnabled)")

        // Keep menu bar icon in sync with recording state
        sessionCancellable = RecordingSession.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                guard let self else { return }
                if recording {
                    self.recordingState = .recording
                } else {
                    // Restore upcoming state if there's still a pending event
                    self.recordingState = CalendarManager.shared.upcomingEvent != nil ? .upcoming : .idle
                }
            }

        calendarCancellable = CalendarManager.shared.$upcomingEvent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                // Only show upcoming state when idle
                if case .idle = self.recordingState {
                    self.recordingState = event != nil ? .upcoming : .idle
                } else if event == nil, case .upcoming = self.recordingState {
                    self.recordingState = .idle
                }
            }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateStatusIcon()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(appDelegate: self)
        )
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            openMainWindow()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Icon States

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        pulseTimer?.invalidate()
        pulseTimer = nil
        button.alphaValue = 1.0

        switch recordingState {
        case .idle:
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Memgram idle")?
                .withSymbolConfiguration(config)
            button.image = image
            button.contentTintColor = .secondaryLabelColor

        case .upcoming:
            let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [.systemPurple])
            let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let config = sizeConfig.applying(paletteConfig)
            let image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Meeting starting soon")?
                .withSymbolConfiguration(config)
            button.image = image
            button.contentTintColor = nil
            startUpcomingPulseAnimation(button: button)

        case .recording:
            // Use a palette configuration to force red regardless of menu bar appearance
            let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let config = sizeConfig.applying(paletteConfig)
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Memgram recording")?
                .withSymbolConfiguration(config)
            button.image = image
            button.contentTintColor = nil  // palette config handles the color
            startPulseAnimation(button: button)

        case .processing:
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Memgram processing")?
                .withSymbolConfiguration(config)
            button.image = image
            button.contentTintColor = .secondaryLabelColor
        }
    }

    private func startUpcomingPulseAnimation(button: NSStatusBarButton) {
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak button] _ in
            guard let button else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.8
                button.animator().alphaValue = button.alphaValue < 0.5 ? 1.0 : 0.5
            }
        }
        pulseTimer?.fire()
    }

    private func startPulseAnimation(button: NSStatusBarButton) {
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak button] _ in
            guard let button else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                button.animator().alphaValue = button.alphaValue < 0.5 ? 1.0 : 0.3
            }
        }
        pulseTimer?.fire()
    }

    // MARK: - Main Window

    func openMainWindow() {
        if mainWindow == nil {
            let hostingController = NSHostingController(rootView: MainWindowView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Memgram"
            window.setContentSize(NSSize(width: 900, height: 600))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }


    // MARK: - Onboarding

    private func showOnboardingIfNeeded() {
        let hasShownOnboarding = UserDefaults.standard.bool(forKey: "hasShownOnboarding")
        guard !hasShownOnboarding else { return }
        PermissionsManager.shared.requestPermissionsSequentially()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == CalendarNotificationService.startRecordingActionId else { return }
        await Task { @MainActor in
            let eventId = response.notification.request.content.userInfo["eventIdentifier"] as? String
            // Try lookup by identifier first, fall back to time-based search
            let store = EKEventStore()
            let event = eventId.flatMap { store.event(withIdentifier: $0) }
                ?? CalendarManager.shared.findEvent(around: Date(), toleranceMinutes: 30)
            if let event {
                let ctx = CalendarManager.shared.context(for: event)
                try? await RecordingSession.shared.start(calendarContext: ctx)
            } else {
                try? await RecordingSession.shared.start()
            }
        }.value
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
