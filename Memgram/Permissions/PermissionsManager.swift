import AVFoundation
import CoreAudio
import ScreenCaptureKit
import AppKit
import SwiftUI

final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var microphoneGranted: Bool = false
    @Published var systemAudioGranted: Bool = false
    @Published var showOnboardingSheet: Bool = false

    private init() {
        checkStoredPermissions()
    }

    // MARK: - Permission State

    private func checkStoredPermissions() {
        // Mic: check actual TCC state
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = (micStatus == .authorized)
        UserDefaults.standard.set(microphoneGranted, forKey: "microphonePermissionGranted")

        // System audio: attempt a real tap with current process IDs to verify TCC state.
        // Falls back to UserDefaults when no audio processes are running (early startup).
        if #available(macOS 14.4, *) {
            let processIDs = Self.audioProcessObjectIDs()
            if processIDs.isEmpty {
                // No audio processes to tap — can't verify. Default to false (safe)
                // and schedule a re-check once audio processes are available.
                systemAudioGranted = false
                scheduleSystemAudioRecheck()
            } else {
                systemAudioGranted = Self.probeAudioTapPermission(processIDs: processIDs)
                UserDefaults.standard.set(systemAudioGranted, forKey: "systemAudioPermissionGranted")
            }
        } else {
            systemAudioGranted = UserDefaults.standard.bool(forKey: "systemAudioPermissionGranted")
        }
    }

    @available(macOS 14.4, *)
    private func scheduleSystemAudioRecheck() {
        Task {
            // Retry a few times over ~5s waiting for audio processes to appear
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let processIDs = Self.audioProcessObjectIDs()
                guard !processIDs.isEmpty else { continue }
                let granted = Self.probeAudioTapPermission(processIDs: processIDs)
                await MainActor.run {
                    systemAudioGranted = granted
                    UserDefaults.standard.set(granted, forKey: "systemAudioPermissionGranted")
                }
                return
            }
        }
    }

    // MARK: - Sequential Permission Request

    func requestPermissionsSequentially() {
        UserDefaults.standard.set(true, forKey: "hasShownOnboarding")
        showOnboardingSheet = true
    }

    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            await MainActor.run {
                microphoneGranted = true
                UserDefaults.standard.set(true, forKey: "microphonePermissionGranted")
            }
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                microphoneGranted = granted
                UserDefaults.standard.set(granted, forKey: "microphonePermissionGranted")
            }
            return granted
        case .denied, .restricted:
            await MainActor.run { microphoneGranted = false }
            return false
        @unknown default:
            return false
        }
    }

    func requestSystemAudioPermission() async -> Bool {
        if #available(macOS 14.4, *) {
            return await requestCoreAudioTapPermission()
        } else {
            return await requestScreenCapturePermission()
        }
    }

    @available(macOS 14.4, *)
    private func requestCoreAudioTapPermission() async -> Bool {
        var processIDs = Self.audioProcessObjectIDs()
        if processIDs.isEmpty {
            try? await Task.sleep(nanoseconds: 500_000_000)
            processIDs = Self.audioProcessObjectIDs()
        }
        guard !processIDs.isEmpty else { return false }

        // First probe triggers the dedicated CoreAudio permission dialog
        // ("Memgram would like to access audio from other apps") — this is NOT
        // Screen Recording. The call is synchronous and returns immediately before
        // the user responds, so we poll until granted or timeout.
        _ = Self.probeAudioTapPermission(processIDs: processIDs)

        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s per poll
            let granted = Self.probeAudioTapPermission(processIDs: processIDs)
            if granted {
                await MainActor.run {
                    systemAudioGranted = true
                    UserDefaults.standard.set(true, forKey: "systemAudioPermissionGranted")
                }
                return true
            }
        }
        return false
    }

    /// Attempt to create and immediately destroy a tap. Returns true if TCC allows it.
    @available(macOS 14.4, *)
    private static func probeAudioTapPermission(processIDs: [AudioObjectID]) -> Bool {
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tapDesc.name = "MemgramPermCheck"
        tapDesc.isExclusive = false
        let status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        return status == noErr
    }

    /// Returns all currently running audio process object IDs.
    @available(macOS 14.4, *)
    static func audioProcessObjectIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids
    }

    private func requestScreenCapturePermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await MainActor.run {
                systemAudioGranted = true
                UserDefaults.standard.set(true, forKey: "systemAudioPermissionGranted")
            }
            return true
        } catch {
            await MainActor.run { systemAudioGranted = false }
            return false
        }
    }

    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func markOnboardingComplete() {
        UserDefaults.standard.set(true, forKey: "hasShownOnboarding")
        showOnboardingSheet = false
    }
}
