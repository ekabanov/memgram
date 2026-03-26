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
        // Check actual system state, not just what we stored
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneGranted = (micStatus == .authorized)
        UserDefaults.standard.set(microphoneGranted, forKey: "microphonePermissionGranted")

        // System audio: for CoreAudio tap (14.4+) the audio-input entitlement suffices.
        // For SCKit (<14.4) we rely on what was granted during onboarding.
        systemAudioGranted = UserDefaults.standard.bool(forKey: "systemAudioPermissionGranted")
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
        // Actually create a ProcessTap to trigger the TCC permission dialog now,
        // during onboarding — not on the first recording attempt.
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [AudioObjectID(kAudioObjectSystemObject)])
        tapDesc.name = "MemgramPermissionCheck"
        tapDesc.isExclusive = false

        let status = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }

        let granted = (status == noErr)
        await MainActor.run {
            systemAudioGranted = granted
            UserDefaults.standard.set(granted, forKey: "systemAudioPermissionGranted")
        }
        return granted
    }

    private func requestScreenCapturePermission() async -> Bool {
        do {
            // Triggers the system permission dialog for screen/audio capture
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            await MainActor.run {
                systemAudioGranted = true
                UserDefaults.standard.set(true, forKey: "systemAudioPermissionGranted")
            }
            return true
        } catch {
            await MainActor.run {
                systemAudioGranted = false
            }
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
