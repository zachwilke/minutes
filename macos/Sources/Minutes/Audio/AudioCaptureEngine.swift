import Foundation
import AVFoundation

/// Merges the microphone and system output into a single 16 kHz mono timeline,
/// writes it to disk, and hands the same samples to the live transcriber.
///
/// The two sources behave very differently. The microphone delivers buffers
/// continuously, silence included. A Core Audio process tap only fires while
/// something is actually playing — verified: zero callbacks when the Mac is
/// quiet. Simply appending whatever arrives would therefore squeeze the silences
/// out of the remote side and drift it steadily earlier than the microphone.
///
/// So each buffer is placed at the absolute sample index its host timestamp
/// implies, gaps are filled with real silence, and mixing runs a fixed distance
/// behind real time. That gives every source a grace period to deliver late
/// audio, and keeps both sides locked to one timeline for the whole meeting.
/// Thread safety: every mutable field is guarded by `lock`, and the callbacks
/// fire on Core Audio's realtime thread and the mixer queue by design.
final class AudioCaptureEngine: @unchecked Sendable {
    struct Levels: Sendable {
        var mic: Float = 0
        var system: Float = 0
        /// The recording file stopped accepting writes.
        var writeFailed = false
    }

    struct Result: Sendable {
        var duration: TimeInterval
        var energy: EnergyTrack
        var capturedMic: Bool
        var capturedSystem: Bool
        /// Raw counts, so a silent recording can be diagnosed: did the device
        /// deliver nothing, or did we fail to convert what it delivered?
        var micBuffersReceived: Int
        var systemBuffersReceived: Int
        var micSamplesResampled: Int
        var systemSamplesResampled: Int
        /// Loudest level seen on each source. A capture that ran but is pure
        /// silence is the signature of a missing Audio Recording permission.
        var peakMicLevel: Float
        var peakSystemLevel: Float
        /// Set when one source was unavailable but recording continued anyway.
        var degradedReason: String?
    }

    /// Called with each mixed chunk, for live transcription.
    var onMixedChunk: (@Sendable ([Float]) -> Void)?
    /// Called ~10x/second with current input levels, for the UI meters.
    var onLevels: (@Sendable (Levels) -> Void)?

    private let mic = MicCapture()
    private let systemTap = SystemAudioTap()
    private var micResampler: Resampler?
    private var systemResampler: Resampler?

    private let lock = NSLock()
    private var micTimeline = SourceTimeline()
    private var systemTimeline = SourceTimeline()
    /// Absolute sample index already written to the WAV.
    private var consumedUpTo = 0
    /// Host time of the very first buffer, the origin of our timeline.
    private var startHostTime: UInt64 = 0
    private var startSeconds: TimeInterval = 0

    private var writer: WAVWriter?
    private var energy = EnergyTrack()
    private var mixTimer: DispatchSourceTimer?
    private let mixQueue = DispatchQueue(label: "com.minutesapp.Minutes.mixer", qos: .userInitiated)

    private var capturedMic = false
    private var capturedSystem = false
    private var peakMic: Float = 0
    private var peakSystem: Float = 0
    private var startCompletions = 0
    private var startFailures: [Error] = []
    private var stoppedWhileStarting = false
    private var requestedMic = false
    private var requestedSystem = false

    private static let sampleRate = WAVWriter.sampleRate
    /// How far behind real time we mix. Long enough to absorb device jitter and a
    /// tap that fires in bursts, short enough that live text stays live.
    private static let latencySamples = sampleRate * 400 / 1000
    /// A gap longer than this is treated as a timestamp glitch, not real silence.
    private static let maxGapSamples = sampleRate * 30

    // MARK: - Lifecycle

    /// Starts capture. Throws only if *neither* source can be captured; losing
    /// just one degrades to a single-source recording and reports why.
    ///
    /// The two `capture...` flags default to the user's settings but can be
    /// overridden, which the command line diagnostics rely on.
    func start(writingTo url: URL,
               captureMic: Bool = AppSettings.shared.captureMicrophone,
               captureSystem: Bool = AppSettings.shared.captureSystemAudio) throws {
        writer = try WAVWriter(url: url)
        energy = EnergyTrack()
        consumedUpTo = 0
        startHostTime = 0
        peakMic = 0
        peakSystem = 0
        startCompletions = 0
        startFailures = []
        stoppedWhileStarting = false
        requestedMic = captureMic
        requestedSystem = captureSystem
        micTimeline = SourceTimeline()
        systemTimeline = SourceTimeline()

        // The two sources start in parallel, and the call returns as soon as the
        // FIRST one is capturing. Each involves real hardware setup — the tap
        // builds an aggregate device (~100ms), the mic spins up AVAudioEngine
        // (~500ms, hardware) — and the timeline places every buffer by host
        // time, so audio flows from the moment the fastest source is live. The
        // slower one attaches in the background and its buffers land exactly
        // where they belong; waiting for it bought nothing but UI lag.
        let gate = DispatchSemaphore(value: 0)
        let startQueue = DispatchQueue(label: "com.minutesapp.Minutes.capturestart",
                                      qos: .userInitiated, attributes: .concurrent)
        let expected = (captureSystem ? 1 : 0) + (captureMic ? 1 : 0)

        func complete(isMic: Bool, resampler: Resampler?, error: Error?, ms: Int) {
            lock.lock()
            if isMic {
                micResampler = resampler
                capturedMic = resampler != nil
                if let error { startFailures.append(error) }
            } else {
                systemResampler = resampler
                capturedSystem = resampler != nil
                if let error { startFailures.append(error) }
            }
            startCompletions += 1
            let successes = (capturedMic ? 1 : 0) + (capturedSystem ? 1 : 0)
            let done = startCompletions == expected
            // A source that comes up after stop() has no owner; kill it here.
            let orphaned = stoppedWhileStarting && resampler != nil
            lock.unlock()

            Log.info("\(isMic ? "Mic" : "System audio") \(resampler != nil ? "capturing" : "failed") after \(ms)ms")
            if orphaned {
                if isMic { mic.stop() } else { systemTap.stop() }
                return
            }
            // Release the caller on the first success, or once everything has
            // reported so a total failure can throw.
            if (resampler != nil && successes == 1) || done {
                gate.signal()
            }
        }

        if captureSystem {
            startQueue.async { [systemTap, self] in
                let began = Date()
                var resampler: Resampler?
                var failure: Error?
                do {
                    try systemTap.start { [weak self] buffer, hostTime in
                        self?.ingest(buffer, hostTime: hostTime, isMic: false)
                    }
                    resampler = systemTap.format.flatMap { Resampler(from: $0) }
                } catch {
                    failure = error
                    Log.warn("System audio unavailable: \(error.localizedDescription)")
                }
                complete(isMic: false, resampler: resampler, error: failure,
                         ms: Int(Date().timeIntervalSince(began) * 1000))
            }
        }

        if captureMic {
            startQueue.async { [mic, self] in
                let began = Date()
                var resampler: Resampler?
                var failure: Error?
                do {
                    try mic.start { [weak self] buffer, hostTime in
                        self?.ingest(buffer, hostTime: hostTime, isMic: true)
                    }
                    resampler = mic.format.flatMap { Resampler(from: $0) }
                } catch {
                    failure = error
                    Log.warn("Microphone unavailable: \(error.localizedDescription)")
                }
                complete(isMic: true, resampler: resampler, error: failure,
                         ms: Int(Date().timeIntervalSince(began) * 1000))
            }
        }

        gate.wait()

        lock.lock()
        let anyLive = capturedMic || capturedSystem
        let failures = startFailures
        lock.unlock()

        guard anyLive else {
            writer?.close()
            writer = nil
            let reason = failures.map(\.localizedDescription).joined(separator: " ")
            throw NSError(domain: "Minutes", code: -2, userInfo: [
                NSLocalizedDescriptionKey: reason.isEmpty ? "No audio sources could be opened." : reason
            ])
        }

        startMixTimer()
        Log.info("Capture started; remaining sources attach in the background")
    }
    func stop() -> Result {
        lock.lock()
        stoppedWhileStarting = true
        lock.unlock()
        mixTimer?.cancel()
        mixTimer = nil
        mic.stop()
        systemTap.stop()

        // Cancelling the timer does not wait for a drain already in progress, so
        // the final flush and the close run on the mixer queue behind it. Run
        // here instead, the two drains raced on the energy track and the writer.
        let duration: TimeInterval = mixQueue.sync {
            // Flush whatever is still buffered so we don't clip the last words.
            drain(flushing: true)
            let duration = writer?.duration ?? 0
            writer?.close()
            writer = nil
            return duration
        }

        lock.lock()
        let counts = (micTimeline.buffersReceived, systemTimeline.buffersReceived,
                      micTimeline.samplesResampled, systemTimeline.samplesResampled)
        let peaks = (peakMic, peakSystem)
        // Derived at stop rather than at start, because a source can now succeed
        // or fail after start() has already returned.
        var degradedReason: String?
        if requestedSystem, !capturedSystem {
            degradedReason = startFailures.first?.localizedDescription
                ?? "System audio was unavailable; recorded microphone only."
        } else if requestedMic, !capturedMic {
            degradedReason = startFailures.first?.localizedDescription
                ?? "Microphone was unavailable; recorded system audio only."
        }
        lock.unlock()

        Log.info("Capture stopped after \(String(format: "%.1f", duration))s")

        return Result(duration: duration,
                      energy: energy,
                      capturedMic: capturedMic,
                      capturedSystem: capturedSystem,
                      micBuffersReceived: counts.0,
                      systemBuffersReceived: counts.1,
                      micSamplesResampled: counts.2,
                      systemSamplesResampled: counts.3,
                      peakMicLevel: peaks.0,
                      peakSystemLevel: peaks.1,
                      degradedReason: degradedReason)
    }

    /// The loudness track so far. Read on the mixer queue, which is the only
    /// writer, so the copy is consistent.
    func energySnapshot() -> EnergyTrack {
        mixQueue.sync { energy }
    }

    // MARK: - Ingest

    private func ingest(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, isMic: Bool) {
        // Read under the lock: start() assigns these from the start queue while
        // the other source may already be delivering.
        lock.lock()
        var resampler = isMic ? micResampler : systemResampler
        var rebuilt = false
        // A device change mid-meeting can change the sample rate or channel
        // count. Each source's buffers arrive on one thread, so rebuilding here
        // is ordered with respect to that source's own audio.
        if let current = resampler, !current.accepts(buffer.format) {
            resampler = Resampler(from: buffer.format)
            if isMic { micResampler = resampler } else { systemResampler = resampler }
            rebuilt = true
        }
        lock.unlock()
        if rebuilt {
            Log.info("\(isMic ? "Mic" : "System audio") format changed to \(buffer.format.sampleRate) Hz, \(buffer.format.channelCount) ch")
        }
        guard let resampler else { return }
        let samples = resampler.resample(buffer)

        lock.lock()
        defer { lock.unlock() }

        if isMic { micTimeline.buffersReceived += 1 } else { systemTimeline.buffersReceived += 1 }
        guard !samples.isEmpty else { return }

        // The first buffer from either source defines time zero.
        if startHostTime == 0 {
            startHostTime = hostTime
            startSeconds = AVAudioTime.seconds(forHostTime: hostTime)
        }

        let offset = max(0, AVAudioTime.seconds(forHostTime: hostTime) - startSeconds)
        let index = Int(offset * Double(Self.sampleRate))

        if isMic {
            micTimeline.write(samples, at: index, floor: consumedUpTo, maxGap: Self.maxGapSamples)
            micTimeline.lastArrival = CFAbsoluteTimeGetCurrent()
            micTimeline.samplesResampled += samples.count
        } else {
            systemTimeline.write(samples, at: index, floor: consumedUpTo, maxGap: Self.maxGapSamples)
            systemTimeline.lastArrival = CFAbsoluteTimeGetCurrent()
            systemTimeline.samplesResampled += samples.count
        }
    }

    private func startMixTimer() {
        let timer = DispatchSource.makeTimerSource(queue: mixQueue)
        // The mixer already runs 400ms behind real time, so 30ms of leeway for
        // wakeup coalescing costs nothing.
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100),
                       leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.drain(flushing: false) }
        timer.resume()
        mixTimer = timer
    }

    // MARK: - Mix

    private func drain(flushing: Bool) {
        lock.lock()

        guard startHostTime != 0 else { lock.unlock(); return }

        // Mix everything old enough that any late audio has had time to arrive.
        // On the final flush, take whatever is left regardless of age.
        let target: Int
        if flushing {
            target = max(micTimeline.end, systemTimeline.end)
        } else {
            let nowIndex = Int((AVAudioTime.seconds(forHostTime: mach_absolute_time()) - startSeconds)
                               * Double(Self.sampleRate))
            target = nowIndex - Self.latencySamples
        }

        let count = target - consumedUpTo
        guard count > 0 else { lock.unlock(); return }

        // Whatever a source hasn't delivered by now is genuinely silence.
        let micChunk = micTimeline.take(upTo: target, padding: count)
        let systemChunk = systemTimeline.take(upTo: target, padding: count)
        let chunkStartTime = Float(Double(consumedUpTo) / Double(Self.sampleRate))
        consumedUpTo = target
        lock.unlock()

        var mixed = [Float](repeating: 0, count: count)
        var micSquared: Float = 0
        var systemSquared: Float = 0
        for index in 0..<count {
            let micSample = micChunk[index]
            let systemSample = systemChunk[index]
            micSquared += micSample * micSample
            systemSquared += systemSample * systemSample
            // Simple sum with a hard clamp. Both sources are rarely loud at the
            // same time, and attenuating would hurt the quieter speaker.
            mixed[index] = max(-1, min(1, micSample + systemSample))
        }

        let divisor = Float(count)
        let levels = Levels(mic: (micSquared / divisor).squareRoot(),
                            system: (systemSquared / divisor).squareRoot())
        lock.lock()
        peakMic = max(peakMic, levels.mic)
        peakSystem = max(peakSystem, levels.system)
        lock.unlock()
        energy.frames.append(EnergyTrack.Frame(time: chunkStartTime,
                                               mic: levels.mic,
                                               system: levels.system))

        writer?.append(mixed)
        onMixedChunk?(mixed)
        var reported = levels
        reported.writeFailed = writer?.hasFailed ?? false
        onLevels?(reported)
    }
}

/// One source's audio, addressed by absolute sample index rather than by arrival
/// order. This is what keeps a bursty system-audio tap aligned with a continuous
/// microphone feed.
private struct SourceTimeline {
    var enabled = false
    /// Absolute index of `samples[0]`.
    var base = 0
    var samples: [Float] = []
    var lastArrival: CFAbsoluteTime = 0
    var buffersReceived = 0
    var samplesResampled = 0

    var end: Int { base + samples.count }

    /// Places samples at `index`, filling any preceding gap with silence.
    ///
    /// `floor` is how far the mixer has already written; audio older than that
    /// can no longer be positioned, so it is appended at the boundary instead of
    /// being dropped — a small timing error beats losing speech.
    mutating func write(_ new: [Float], at index: Int, floor: Int, maxGap: Int) {
        if samples.isEmpty, base < floor { base = floor }
        let target = max(index, base)
        if target > end {
            // A gap this large means the timestamps are wrong, not that the room
            // was silent for half a minute.
            let gap = min(target - end, maxGap)
            samples.append(contentsOf: repeatElement(0, count: gap))
        }
        samples.append(contentsOf: new)
    }

    /// Consumes samples up to `upTo`, returning exactly `padding` samples with
    /// silence for anything not delivered.
    mutating func take(upTo absolute: Int, padding: Int) -> [Float] {
        var chunk = [Float]()
        let available = max(0, min(absolute, end) - base)
        if available > 0 {
            chunk = Array(samples[0..<available])
            samples.removeFirst(available)
            base += available
        }
        if base < absolute { base = absolute }
        if chunk.count < padding {
            chunk.append(contentsOf: repeatElement(0, count: padding - chunk.count))
        }
        return chunk
    }
}
