import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var step: OnboardingStep = .welcome

    enum OnboardingStep {
        case welcome
        case microphone
        case systemAudio
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            navigationBar
                .padding(16)
        }
        .frame(width: 480, height: 340)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            WelcomeStepView()
        case .microphone:
            PermissionStepView(
                icon: "mic.fill",
                iconColor: .blue,
                title: "Microphone Access",
                description: "Memgram uses your microphone to capture your voice during meetings. Your audio is processed entirely on this device — never sent anywhere.",
                note: "You'll see a standard macOS permission prompt."
            )
        case .systemAudio:
            PermissionStepView(
                icon: "speaker.wave.2.fill",
                iconColor: .purple,
                title: "System Audio Access",
                description: systemAudioDescription,
                note: systemAudioNote
            )
        case .done:
            DoneStepView()
        }
    }

    private var systemAudioDescription: String {
        if #available(macOS 14.4, *) {
            return "Memgram captures system audio to transcribe what the other participants say. This uses a private audio tap — no screen recording required."
        } else {
            return "Memgram captures system audio to transcribe what the other participants say. On your macOS version, this requires Screen Recording permission — but no video is ever recorded or stored."
        }
    }

    private var systemAudioNote: String {
        if #available(macOS 14.4, *) {
            return "Uses CoreAudio private tap — audio plays normally through your speakers."
        } else {
            return "Only audio is captured. No screen content is recorded or stored."
        }
    }

    private var navigationBar: some View {
        HStack {
            stepIndicator
            Spacer()
            navigationButtons
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<5) { i in
                Circle()
                    .fill(currentStepIndex == i ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var currentStepIndex: Int {
        switch step {
        case .welcome:      return 0
        case .microphone:   return 1
        case .systemAudio:  return 2
        case .done:         return 3
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            if step != .welcome {
                Button("Back") { goBack() }
                    .buttonStyle(.plain)
            }
            Button(nextButtonTitle) { goNext() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var nextButtonTitle: String {
        switch step {
        case .welcome:      return "Get Started"
        case .microphone:   return "Allow Microphone"
        case .systemAudio:  return "Allow System Audio"
        case .done:         return "Done"
        }
    }

    private func goNext() {
        switch step {
        case .welcome:
            step = .microphone
        case .microphone:
            Task {
                let granted = await permissions.requestMicrophonePermission()
                await MainActor.run {
                    step = granted ? .systemAudio : .microphone
                }
            }
        case .systemAudio:
            Task {
                _ = await permissions.requestSystemAudioPermission()
                await MainActor.run {
                    permissions.markOnboardingComplete()
                    step = .done
                }
            }
        case .done:
            permissions.markOnboardingComplete()
        }
    }

    private func goBack() {
        switch step {
        case .welcome:      break
        case .microphone:   step = .welcome
        case .systemAudio:  step = .microphone
        case .done:         step = .systemAudio
        }
    }
}

// MARK: - Step Subviews

struct WelcomeStepView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56))
                .foregroundStyle(.blue, .purple)
            VStack(spacing: 8) {
                Text("Welcome to Memgram")
                    .font(.title2.bold())
                Text("Private, offline meeting transcription.\nEvery word remembered — nothing leaves your Mac.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}

struct PermissionStepView: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let note: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(iconColor)
            VStack(spacing: 10) {
                Text(title)
                    .font(.title3.bold())
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Text(note)
                        .font(.caption)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .padding(.top, 4)
            }
        }
        .padding(32)
    }
}

struct DoneStepView: View {
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            VStack(spacing: 8) {
                Text("You're all set!")
                    .font(.title2.bold())
                Text("Memgram is ready to record your meetings.\nClick the menu bar icon to start.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                permissionBadge(icon: "mic.fill", label: "Microphone", granted: permissions.microphoneGranted)
                permissionBadge(icon: "speaker.wave.2.fill", label: "System Audio", granted: permissions.systemAudioGranted)
            }
        }
        .padding(32)
    }

    private func permissionBadge(icon: String, label: String, granted: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Enroll Voice Step

