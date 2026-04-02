import AVFoundation
import CoreAudio
import Combine
import OSLog

private let log = Logger.make("Audio")

@available(macOS 14.4, *)
final class CoreAudioTapCapture: SystemAudioCaptureProvider {

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let subject = PassthroughSubject<AVAudioPCMBuffer, Never>()

    var bufferPublisher: AnyPublisher<AVAudioPCMBuffer, Never> {
        subject.eraseToAnyPublisher()
    }

    func start() async throws {
        teardownHard()

        // STEP 1: Create tap description.
        // Try three strategies in order:
        // A) Empty process list (Apple docs say this = all processes)
        // B) kAudioObjectSystemObject as the "process" (system-wide mix)
        // C) All enumerated audio process object IDs
        let processIDs = Self.allAudioProcessObjectIDs()
        // If no audio processes found yet, fall back to system object (captures all output)
        let tapProcesses: [AudioObjectID] = processIDs.isEmpty
            ? [AudioObjectID(kAudioObjectSystemObject)]
            : processIDs
        log.info("CoreAudioTapCapture: \(processIDs.count) audio processes — strategy: \(processIDs.isEmpty ? "system-fallback" : "process-list")")
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: tapProcesses)
        tapDesc.name = "MemgramSystemTap"
        // isExclusive = false → spy tap (audio still plays through speakers)
        tapDesc.isExclusive = false

        // STEP 2: Create process tap, retry up to 3× on transient errors
        var tapStatus: OSStatus = noErr
        for attempt in 1...3 {
            tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapObjectID)
            if tapStatus == noErr { break }
            if attempt < 3 { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        if tapStatus != noErr {
            log.error("Tap creation failed after 3 attempts: OSStatus \(tapStatus)")
        }
        guard tapStatus == noErr else {
            throw AudioCaptureError.tapCreationFailed(tapStatus)
        }

        // STEP 3: Private aggregate device wrapping the tap
        let aggUID = "com.memgram.audiotap.\(UUID().uuidString)"
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MemgramTap",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDesc.uuid.uuidString]
            ]
        ]
        var aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        if aggStatus == 1852797029 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
            aggStatus = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateDeviceID)
        }
        if aggStatus != noErr {
            log.error("Aggregate device creation failed: OSStatus \(aggStatus)")
        }
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
            throw AudioCaptureError.aggregateDeviceFailed(aggStatus)
        }

        // STEP 4: Read tap format — prefer kAudioTapPropertyFormat on the tap object,
        // fall back to stream format on the aggregate, then a hardcoded default.
        let asbd = Self.readTapFormat(tapID: tapObjectID)
            ?? Self.readStreamFormat(deviceID: aggregateDeviceID, scope: kAudioObjectPropertyScopeInput)
            ?? Self.readStreamFormat(deviceID: aggregateDeviceID, scope: kAudioObjectPropertyScopeOutput)
            ?? Self.fallbackASBD()

        let nativeSampleRate = asbd.mSampleRate
        let nativeChannels = asbd.mChannelsPerFrame
        log.info("Format: \(Int(nativeSampleRate))Hz \(nativeChannels)ch")

        // STEP 5: IOProc
        let subjectCapture = subject
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            inNow, inInputData, inInputTime, outOutputData, inOutputTime in

            guard inInputData.pointee.mNumberBuffers > 0 else { return }
            let buf = inInputData.pointee.mBuffers
            guard let data = buf.mData, buf.mDataByteSize > 0 else { return }

            let frameCount = Int(buf.mDataByteSize) / (MemoryLayout<Float32>.size * Int(max(nativeChannels, 1)))
            guard frameCount > 0 else { return }

            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: nativeSampleRate,
                channels: AVAudioChannelCount(max(nativeChannels, 1)),
                interleaved: true
            ),
            let pcmBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }

            pcmBuf.frameLength = AVAudioFrameCount(frameCount)
            pcmBuf.audioBufferList.pointee.mBuffers.mData!
                .copyMemory(from: data, byteCount: Int(buf.mDataByteSize))

            if let resampled = AudioConverter.resampleToMono16k(pcmBuf) {
                subjectCapture.send(resampled)
            }
        }
        if procStatus != noErr || procID == nil {
            log.error("IOProc creation failed: OSStatus \(procStatus)")
        }
        guard procStatus == noErr, let procID else {
            teardownHard()
            throw AudioCaptureError.ioProcFailed(procStatus)
        }
        self.ioProcID = procID
        AudioDeviceStart(aggregateDeviceID, procID)
        log.info("CoreAudioTapCapture started")
    }

    func stop() async {
        teardownHard()
    }

    // MARK: - Format helpers

    /// Read the tap's own declared format — most accurate source.
    private static func readTapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        return (status == noErr && asbd.mSampleRate > 0) ? asbd : nil
    }

    private static func readStreamFormat(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var streamListSize: UInt32 = 0
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamListSize) == noErr,
              streamListSize > 0 else { return nil }

        let count = Int(streamListSize) / MemoryLayout<AudioObjectID>.size
        var streamIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &streamListSize, &streamIDs)

        guard let streamID = streamIDs.first, streamID != kAudioObjectUnknown else { return nil }

        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        var formatAddr = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(streamID, &formatAddr, 0, nil, &formatSize, &asbd)
        return (status == noErr && asbd.mSampleRate > 0) ? asbd : nil
    }

    private static func fallbackASBD() -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = 48000
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mBitsPerChannel = 32
        asbd.mChannelsPerFrame = 2
        asbd.mBytesPerFrame = 8
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerPacket = 8
        return asbd
    }

    /// Returns AudioObjectIDs for all currently running audio processes.
    /// Passing these to CATapDescription ensures we capture from all of them.
    private static func allAudioProcessObjectIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids)
        return ids
    }

    // MARK: - Teardown

    private func teardownHard() {
        if let procID = ioProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
    }
}
