#if os(macOS)
import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger.make("Hotkey")

/// Registers the fixed global ⌥⌘R hotkey via Carbon `RegisterEventHotKey`.
/// This works inside the App Sandbox and requires NO accessibility permission —
/// unlike `NSEvent.addGlobalMonitorForEvents`, which silently receives nothing
/// without it. The hotkey lets users stop a recording even when macOS hides
/// the menu bar icon (crowded menu bar).
final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Fired on the main actor when ⌥⌘R is pressed.
    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// 'MGRM' — identifies our hotkey in the Carbon event callback.
    private static let hotKeyId = EventHotKeyID(signature: OSType(0x4D47_524D), id: 1)

    private init() {}

    /// Registers ⌥⌘R. Safe to call repeatedly — no-op if already registered.
    func register() {
        guard hotKeyRef == nil else { return }
        installEventHandlerIfNeeded()
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | optionKey),
            Self.hotKeyId,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            log.info("Registered global hotkey ⌥⌘R")
        } else {
            hotKeyRef = nil
            log.error("RegisterEventHotKey failed with status \(status)")
        }
    }

    /// Unregisters the hotkey. Safe to call repeatedly.
    func unregister() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
        log.info("Unregistered global hotkey ⌥⌘R")
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                var pressedId = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedId
                )
                guard pressedId.signature == HotkeyManager.hotKeyId.signature,
                      pressedId.id == HotkeyManager.hotKeyId.id,
                      let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onHotkey?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        if status != noErr {
            eventHandlerRef = nil
            log.error("InstallEventHandler failed with status \(status)")
        }
    }
}
#endif
