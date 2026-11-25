import AVFoundation

/// Microphone input — this is what picks up in-person meetings and your own
/// voice on a call.
final class MicCapture {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer, UInt64) -> Void

    /// Replaced, not reused, when falling back from voice processing: an engine
    /// that has had it enabled keeps a stale format even after it is disabled.
    private var engine = AVAudioEngine()
    private var isRunning = false
    /// Apple's voice processing (the echo canceller FaceTime uses) on the
    /// microphone. Without it, a call played through speakers is picked up by
    /// the mic: measured on a real Teams call, the "You" track followed the far
    /// side to within 2 dB — so the meter moved while the user was silent, and
    /// speaker labels sat on the You/Them threshold. Meeting apps cancel that
    /// echo for what they send; we read the raw microphone, so we must too.
    let echoCancellation: Bool
    /// Whether voice processing actually engaged, for diagnostics.
    private(set) var echoCancellationActive = false

    init(echoCancellation: Bool = AppSettings.shared.echoCancellation) {
        self.echoCancellation = echoCancellation
    }
    private var onBuffer: BufferHandler?
    private var configurationObserver: NSObjectProtocol?
    /// Serialises start, stop and device-change restarts.
    private let control = DispatchQueue(label: "com.minutesapp.Minutes.mic")

    private(set) var format: AVAudioFormat?

    /// Asks for microphone access, returning the granted state.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(onBuffer: @escaping BufferHandler) throws {
        try control.sync {
            guard !isRunning else { return }
            self.onBuffer = onBuffer
            try startEngine()
            isRunning = true
            observeConfigurationChanges()
            Log.info("Mic capture started")
        }
    }

    private func startEngine() throws {
        do {
            try startEngine(voiceProcessing: echoCancellation)
        } catch where echoCancellation {
            // Voice processing can fail to initialise (seen: error -10875). An
            // echo-free mic is not worth a missing one: tear it down and record
            // the raw microphone instead.
            Log.warn("Mic with echo cancellation failed (\(error.localizedDescription)); retrying without it")
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            engine = AVAudioEngine()
            echoCancellationActive = false
            try startEngine(voiceProcessing: false)
            // The change observer watches a specific engine; follow the new one.
            if isRunning { observeConfigurationChanges() }
        }
    }

    private func startEngine(voiceProcessing: Bool) throws {
        guard let onBuffer else { return }
        let input = engine.inputNode
        if voiceProcessing {
            configureVoiceProcessing(on: input)
        }
        // Read after voice processing is configured: enabling it changes the
        // node's format.
        let nodeFormat = input.outputFormat(forBus: 0)
        guard nodeFormat.sampleRate > 0, nodeFormat.channelCount > 0 else {
            throw NSError(domain: "Minutes", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No usable microphone input was found."
            ])
        }
        // With voice processing on, macOS reports the node as many channels
        // (9 on a MacBook Pro — the processor's internal layout), and a tap in
        // that format fails to initialise (-10875). Its output is mono speech,
        // so ask for exactly that.
        let inputFormat = echoCancellationActive
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nodeFormat.sampleRate,
                            channels: 1, interleaved: false) ?? nodeFormat
            : nodeFormat
        format = inputFormat
        Log.info("Mic format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch"
                 + (echoCancellationActive ? " (node reports \(nodeFormat.channelCount)), echo cancellation on" : ""))

        // macOS 27 replaced installTap with installAudioTap, which hands over a
        // Sendable read-only buffer; bridging it also gives us the copy we need
        // to retain samples past the callback.
        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, when in
            let hostTime = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            onBuffer(AVAudioPCMBuffer(copying: buffer), hostTime)
        }
        engine.prepare()
        try engine.start()
    }

    private func configureVoiceProcessing(on input: AVAudioInputNode) {
        do {
            if !input.isVoiceProcessingEnabled {
                try input.setVoiceProcessingEnabled(true)
            }
            // Voice processing ducks other audio by default — the meeting
            // itself would get quieter the moment recording started.
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false,
                                                                     duckingLevel: .min)
            // Its AGC would pump the level the speaker labels compare.
            input.isVoiceProcessingAGCEnabled = false
            // Leave the output side untouched. Creating the main mixer — even
            // just to mute it — makes the voice-processing unit fail to
            // initialise (-10875); probed on a MacBook Pro, without it the mic
            // hears speaker playback 30 dB quieter.
            echoCancellationActive = true
        } catch {
            // Recording still works, with the echo; better than no microphone.
            Log.warn("Echo cancellation unavailable: \(error.localizedDescription)")
            echoCancellationActive = false
        }
    }

    /// AVAudioEngine stops itself whenever its I/O configuration changes —
    /// AirPods connecting, a headset unplugged, the default input switched — and
    /// does not restart. Unhandled, the microphone went silent for the rest of
    /// the meeting and every segment after it was labelled "Them".
    private func observeConfigurationChanges() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            // The new device is often not ready the instant the change fires.
            self.control.asyncAfter(deadline: .now() + 0.3) { self.restartAfterConfigurationChange() }
        }
    }

    private func restartAfterConfigurationChange() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try startEngine()
            Log.info("Mic capture restarted after a device change")
        } catch {
            // No usable input right now; the next configuration change — a
            // microphone arriving — tries again.
            Log.warn("Mic unavailable after a device change: \(error.localizedDescription)")
        }
    }

    func stop() {
        control.sync {
            guard isRunning else { return }
            isRunning = false
            if let configurationObserver {
                NotificationCenter.default.removeObserver(configurationObserver)
                self.configurationObserver = nil
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            Log.info("Mic capture stopped")
        }
    }

    deinit { stop() }
}
