import Foundation
import CoreAudio
import AVFoundation

enum SystemAudioTapError: LocalizedError {
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case missingOutputDevice
    case unsupportedFormat
    case ioProcFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Minutes needs permission to record system audio. Grant it in System Settings › Privacy & Security › Audio Recording, then start again."
        case .tapCreationFailed(let status):
            return "Could not create the system audio tap (OSStatus \(status))."
        case .aggregateCreationFailed(let status):
            return "Could not create the capture device (OSStatus \(status))."
        case .missingOutputDevice:
            return "No default audio output device was found."
        case .unsupportedFormat:
            return "The system audio tap reported a format we cannot read."
        case .ioProcFailed(let status):
            return "Could not start reading system audio (OSStatus \(status))."
        }
    }
}

/// Captures everything the Mac is playing — Zoom, Teams, Meet, browser tabs —
/// using a Core Audio process tap.
///
/// This deliberately avoids ScreenCaptureKit: an audio-only process tap is gated
/// by the Audio Recording permission instead of Screen Recording, so macOS does
/// not re-prompt every week, and we never touch video frames.
///
/// The tap is global-but-excluding-ourselves so we don't capture our own output,
/// and its mute behavior is left at the default (unmuted) so the user still
/// hears the meeting normally while we record.
final class SystemAudioTap {
    /// Delivers a deep-copied buffer plus the host time of its first sample,
    /// which the mixer needs to place it on a shared timeline. Safe to retain
    /// past the callback.
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var captureFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "com.minutesapp.Minutes.systemtap", qos: .userInitiated)
    private var isRunning = false
    private var onBuffer: BufferHandler?
    /// Serialises start, stop and rebuilds after an output device change. Kept
    /// separate from `queue`: stopping an IOProc from its own queue would wait
    /// on itself.
    private let control = DispatchQueue(label: "com.minutesapp.Minutes.systemtap.control")
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var rebuildGeneration = 0
    /// Counts raw IOProc invocations and successful conversions separately, so a
    /// silent capture can be traced to the device or to our own conversion.
    private let callbackCounter = CallbackCounter()

    var format: AVAudioFormat? { captureFormat }
    var diagnostics: (invocations: Int, converted: Int) { callbackCounter.snapshot }

    func start(onBuffer: @escaping BufferHandler) throws {
        try control.sync {
            guard !isRunning else { return }
            self.onBuffer = onBuffer
            try build()
            isRunning = true
            observeDefaultOutput()
            Log.info("System audio tap started")
        }
    }

    /// Creates the tap, the aggregate device around it and the IOProc. Anything
    /// already created is destroyed if a later step fails — several of these
    /// throws used to leave a live tap and aggregate device behind.
    private func build() throws {
        do {
            try buildUnchecked()
        } catch {
            cleanUp()
            throw error
        }
    }

    private func buildUnchecked() throws {
        guard let onBuffer else { return }

        // The exclusion list must stay empty. Passing our own process object here
        // (to avoid capturing our own output) makes Core Audio create the tap and
        // report success, then never fire the IOProc at all — verified: 0
        // callbacks with an exclusion list, ~75/second without. We play no audio
        // ourselves, so there is nothing to exclude anyway.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Minutes System Audio"
        description.isPrivate = true          // invisible to other apps' device lists

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        if status != noErr {
            // The tap API reports a generic failure rather than a distinct code
            // when the TCC prompt has been declined, so treat it as permission.
            Log.error("AudioHardwareCreateProcessTap failed: \(status)")
            throw status == kAudioHardwareIllegalOperationError
                ? SystemAudioTapError.permissionDenied
                : SystemAudioTapError.tapCreationFailed(status)
        }

        let tapUID: String = try Self.property(tapID, kAudioTapPropertyUID)
        let asbd: AudioStreamBasicDescription = try Self.property(tapID, kAudioTapPropertyFormat)
        // Deliberately not AVAudioFormat(streamDescription:) — the tap reports a
        // packed-interleaved float layout, and AVAudioPCMBuffer refuses to wrap
        // the incoming buffer list under that description. We only ever request a
        // mono tap, so describing it as non-interleaved float is equivalent and
        // gives us a format floatChannelData will actually work with.
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: asbd.mSampleRate,
                                         channels: asbd.mChannelsPerFrame,
                                         interleaved: false)
        else {
            throw SystemAudioTapError.unsupportedFormat
        }
        captureFormat = format
        Log.info("System tap format: \(format.sampleRate) Hz, \(format.channelCount) ch")

        // The aggregate device needs a real output device as its clock source.
        let outputDeviceID: AudioObjectID = try Self.property(AudioObjectID(kAudioObjectSystemObject),
                                                             kAudioHardwarePropertyDefaultOutputDevice)
        guard outputDeviceID != kAudioObjectUnknown else { throw SystemAudioTapError.missingOutputDevice }
        let outputUID: String = try Self.property(outputDeviceID, kAudioDevicePropertyDeviceUID)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minutes Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]

        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            cleanUp()
            throw SystemAudioTapError.aggregateCreationFailed(status)
        }

        let counter = callbackCounter
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, inInputData, inInputTime, _, _ in
            counter.countInvocation()
            guard let copied = Self.copyBuffer(from: inInputData, format: format) else { return }
            counter.countConversion()
            // A tap only fires while something is actually playing, so the host
            // time is the only way to know where this audio belongs relative to
            // the microphone.
            let stamp = inInputTime.pointee
            let hostTime = (stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0)
                ? stamp.mHostTime
                : mach_absolute_time()
            onBuffer(copied, hostTime)
        }
        guard status == noErr, ioProcID != nil else {
            throw SystemAudioTapError.ioProcFailed(status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw SystemAudioTapError.ioProcFailed(status)
        }
    }

    func stop() {
        control.sync {
            guard isRunning else { return }
            isRunning = false
            removeDefaultOutputObserver()
            tearDown()
            let counts = callbackCounter.snapshot
            Log.info("System audio tap stopped (\(counts.invocations) IO callbacks, \(counts.converted) converted)")
        }
    }

    private func tearDown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown { AudioDeviceStop(aggregateID, ioProcID) }
        cleanUp()
    }

    // MARK: - Output device changes

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// The aggregate device is clocked by whatever the default output was at
    /// start. Switch to headphones, or unplug that device, and the old aggregate
    /// stops delivering — the far side of the call went missing. So rebuild
    /// around the new default whenever it changes.
    private func observeDefaultOutput() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.control.async {
                // Device switches arrive in bursts; rebuild once they settle.
                self.rebuildGeneration += 1
                let generation = self.rebuildGeneration
                self.control.asyncAfter(deadline: .now() + 0.5) {
                    guard generation == self.rebuildGeneration else { return }
                    self.rebuildAfterOutputChange()
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                         &Self.defaultOutputAddress, control, listener)
        if status == noErr { outputListener = listener }
    }

    private func removeDefaultOutputObserver() {
        guard let outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &Self.defaultOutputAddress, control, outputListener)
        self.outputListener = nil
    }

    private func rebuildAfterOutputChange() {
        guard isRunning else { return }
        tearDown()
        do {
            try build()
            Log.info("System audio tap rebuilt for the new output device")
        } catch {
            // Stays registered: the next output change tries again.
            Log.warn("System audio unavailable after an output change: \(error.localizedDescription)")
        }
    }

    private func cleanUp() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    // MARK: - Core Audio plumbing

    /// Copies an incoming AudioBufferList into a buffer we own. The list handed
    /// to an IOProc is only valid for the duration of the callback, so this must
    /// copy rather than wrap.
    private static func copyBuffer(from list: UnsafePointer<AudioBufferList>,
                                   format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard all.count > 0 else { return nil }

        let channelCount = Int(format.channelCount)
        let bytesPerSample = MemoryLayout<Float>.size

        // The aggregate's input list is the clock device's own input streams,
        // if it has any, followed by the tap. Usually that is just the tap —
        // but an output device with inputs (a USB headset), or one that voice
        // processing has given a 6-channel echo-reference stream (the built-in
        // speakers, the moment echo cancellation starts), puts other buffers
        // first. Reading buffers[0] then recorded the wrong stream, at six
        // times the frame count: 4 s of capture came out as 19 s of audio. So
        // take the tap's buffers from the end.
        let tapBufferCount = all.count > 1 && channelCount > 1
            && all.suffix(channelCount).allSatisfy({ $0.mNumberChannels == 1 }) ? channelCount : 1
        let buffers = Array(all.suffix(tapBufferCount))

        // Either one buffer per channel (non-interleaved) or a single interleaved
        // buffer holding every channel.
        let isInterleaved = buffers.count == 1 && channelCount > 1
        let frameCount = isInterleaved
            ? Int(buffers[0].mDataByteSize) / (bytesPerSample * channelCount)
            : Int(buffers[0].mDataByteSize) / bytesPerSample

        guard frameCount > 0,
              let destination = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: AVAudioFrameCount(frameCount)),
              let dst = destination.floatChannelData
        else { return nil }

        destination.frameLength = AVAudioFrameCount(frameCount)

        if isInterleaved {
            guard let src = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    dst[channel][frame] = src[frame * channelCount + channel]
                }
            }
        } else {
            for channel in 0..<min(channelCount, buffers.count) {
                guard let src = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                dst[channel].update(from: src, count: frameCount)
            }
        }
        return destination
    }

    /// Generic typed property read for fixed-layout values.
    private static func property<T>(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                     alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer)
        guard status == noErr else { throw SystemAudioTapError.tapCreationFailed(status) }
        return buffer.load(as: T.self)
    }

    /// String properties come back as a retained CFString we must bridge and release.
    private static func property(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let result = value as String? else {
            throw SystemAudioTapError.tapCreationFailed(status)
        }
        return result
    }
}


/// IOProc callbacks arrive on a realtime thread; counting needs to be cheap and
/// thread-safe.
private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var invocations = 0
    private var converted = 0

    func countInvocation() { lock.lock(); invocations += 1; lock.unlock() }
    func countConversion() { lock.lock(); converted += 1; lock.unlock() }


    var snapshot: (invocations: Int, converted: Int) {
        lock.lock(); defer { lock.unlock() }
        return (invocations, converted)
    }
}
