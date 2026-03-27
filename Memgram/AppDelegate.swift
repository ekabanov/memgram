import AppKit
import SwiftUI
import Combine
import AVFoundation

enum RecordingState {
    case idle
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        showOnboardingIfNeeded()
        RecordingSession.shared.loadInterruptedMeetings()
        SummaryEngine.shared.cleanExistingSummaries()

        // Keep menu bar icon in sync with recording state
        sessionCancellable = RecordingSession.shared.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording in
                self?.recordingState = recording ? .recording : .idle
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
