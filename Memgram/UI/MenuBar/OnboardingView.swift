import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var step: OnboardingStep = .welcome

    enum OnboardingStep {
        case welcome
        case microphone
        case systemAudio
        case enrollVoice
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
        case .enrollVoice:
            EnrollVoiceStepView(onComplete: {
                step = .done
            }, onSkip: {
                step = .done
            })
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
        case .enrollVoice:  return 3
        case .done:         return 4
        }
    }

    private var navigationButtons: some View {
        Group {
            if step == .enrollVoice {
                EmptyView()
            } else {
                HStack(spacing: 8) {
                    if step != .welcome {
                        Button("Back") { goBack() }
                            .buttonStyle(.plain)
                    }
                    Button(nextButtonTitle) { goNext() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var nextButtonTitle: String {
        switch step {
        case .welcome:      return "Get Started"
        case .microphone:   return "Allow Microphone"
        case .systemAudio:  return "Allow System Audio"
        case .enrollVoice:  return "Done"
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
                await MainActor.run { step = .enrollVoice }
            }
        case .enrollVoice:
            permissions.markOnboardingComplete()
        case .done:
            permissions.markOnboardingComplete()
        }
    }

    private func goBack() {
        switch step {
        case .welcome:      break
        case .microphone:   step = .welcome
        case .systemAudio:  step = .microphone
        case .enrollVoice:  step = .systemAudio
        case .done:         step = .enrollVoice
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

struct EnrollVoiceStepView: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var name: String = NSFullUserName()
    @State private var isRecording = false
    @State private var progress: Double = 0
    @State private var recorded = false
    @State private var samples: [Float] = []

    private let targetDuration: Double = 5.0
    private let sampleRate: Double = 16_000
    private var targetSamples: Int { Int(sampleRate * targetDuration) }

    @State private var engine: AVAudioEngine? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: recorded ? "person.fill.checkmark" : "waveform.circle")
                .font(.system(size: 44))
                .foregroundColor(recorded ? .green : .accentColor)
                .animation(.easeInOut, value: recorded)

            VStack(spacing: 8) {
                Text("Identify Your Voice")
                    .font(.title3.bold())
                Text("Memgram uses your voice to label who's speaking in meeting transcripts.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Text("Your name:")
                    .foregroundColor(.secondary)
                TextField("Full name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            if recorded {
                Label("Voice sample saved", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.callout)
            } else {
                VStack(spacing: 6) {
                    Button(action: toggleRecording) {
                        ZStack {
                            Circle()
                                .fill(isRecording ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.12))
                                .frame(width: 60, height: 60)
                            if isRecording {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "mic.fill")
                                    .font(.title2)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(isRecording ? "Recording…" : "Click to record 5 seconds of your voice")

                    if isRecording {
                        ProgressView(value: progress)
                            .frame(width: 140)
                            .tint(.red)
                        Text("Recording… \(Int(progress * targetDuration))s / 5s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Click mic to record 5 seconds")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Skip") {
                    stopRecording()
                    onSkip()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                if recorded {
                    Button("Continue") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        SpeakerEnrollmentStore.shared.enrolledName = trimmedName.isEmpty ? nil : trimmedName
                        if !samples.isEmpty {
                            SpeakerEnrollmentStore.shared.saveAudio(samples)
                        }
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        samples = []
        progress = 0
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buf, _ in
            let frameCapacity = AVAudioFrameCount(
                Double(buf.frameLength) * (sampleRate / buf.format.sampleRate)) + 1
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }
            var consumed = false
            try? converter.convert(to: out, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buf
            }
            if let ptr = out.floatChannelData?[0] {
                let arr = Array(UnsafeBufferPointer(start: ptr, count: Int(out.frameLength)))
                DispatchQueue.main.async {
                    self.samples.append(contentsOf: arr)
                    self.progress = min(1.0, Double(self.samples.count) / Double(self.targetSamples))
                    if self.samples.count >= self.targetSamples { self.finishRecording() }
                }
            }
        }
        try? eng.start()
        engine = eng
        isRecording = true
    }

    private func stopRecording() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
    }

    private func finishRecording() {
        stopRecording()
        if samples.count > targetSamples { samples = Array(samples.prefix(targetSamples)) }
        recorded = true
    }
}
