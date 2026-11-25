import Foundation
import AVFoundation
import AppKit

/// Command line diagnostics, so the transcription and summarization pipeline can
/// be exercised without a real meeting:
///
///   Minutes.app/Contents/MacOS/Minutes --selftest path/to/audio.wav
///   Minutes.app/Contents/MacOS/Minutes --test-capture 5
///
/// Handled before any window appears; the process exits when finished.
enum Diagnostics {
    /// Returns true if a diagnostic ran (caller should exit).
    ///
    /// Called from `App.init`, which is on the main actor — `--test-prompt` needs
    /// that, because it puts a real panel on screen and pumps the run loop.
    @MainActor
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count > 1 else { return false }

        if arguments.contains("--test-call-title") {
            let report = CallWindowTitle.report()
            print(report)
            Log.info("Call window titles:\n\(report)")
            return true
        }

        if arguments.contains("--probe-vp") {
            runBlocking { await probeVoiceProcessing() }
            return true
        }

        if arguments.contains("--test-echo") {
            runBlocking { await testEcho() }
            return true
        }

        if arguments.contains("--mcp") {
            MCPServer.run()
            return true
        }

        if let index = arguments.firstIndex(of: "--selftest") {
            let path = index + 1 < arguments.count ? arguments[index + 1] : nil
            runBlocking { await selftest(audioPath: path) }
            return true
        }

        if let index = arguments.firstIndex(of: "--test-capture") {
            let seconds = index + 1 < arguments.count ? Double(arguments[index + 1]) ?? 5 : 5
            runBlocking { await testCapture(seconds: seconds) }
            return true
        }

        if let index = arguments.firstIndex(of: "--ask") {
            let question = index + 1 < arguments.count ? arguments[index + 1] : nil
            runBlocking { await ask(question) }
            return true
        }

        if arguments.contains("--test-prompt") {
            testPrompt()
            return true
        }

        if arguments.contains("--time-start") {
            runBlocking { await timeStart() }
            return true
        }

        if let index = arguments.firstIndex(of: "--watch-detection") {
            let seconds = arguments.dropFirst(index + 1).first.flatMap(TimeInterval.init) ?? 180
            runBlocking { await watchDetection(for: seconds) }
            return true
        }

        if arguments.contains("--test-detection") {
            runBlocking { await testDetection() }
            return true
        }

        if arguments.contains("--dump-prompts") {
            // Written raw rather than via print, which would append a newline the
            // dump string does not contain — shared/prompts/baseline.txt is meant
            // to be the dump byte for byte, so the other platform can diff its own
            // rendering against it.
            FileHandle.standardOutput.write(Data(PromptAudit.dump().utf8))
            return true
        }

        if arguments.contains("--doctor") {
            runBlocking { await doctor() }
            return true
        }

        return false
    }

    /// Bridges async work into the synchronous pre-launch context.
    private static func runBlocking(_ work: @escaping @Sendable () async -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await work()
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Whether we were launched by Finder as an app or from a shell, since TCC
    /// answers differ between the two.
    private static func launchContext() -> String {
        // An app opened by Finder is reparented to launchd; a binary run from a
        // shell keeps the shell as its parent.
        getppid() == 1
            ? "Minutes.app"
            : "the launching terminal, not Minutes.app"
    }

    private static func print(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    // MARK: - Doctor

    static func doctor() async {
        print("Minutes environment check")
        print("---------------------------")
        print("Support folder : \(AppPaths.supportRoot.path)")
        print("whisper-cli    : \(ToolLocator.find("whisper-cli")?.path ?? "NOT FOUND (brew install whisper-cpp)")")
        print("claude         : \(ToolLocator.find("claude")?.path ?? "NOT FOUND (install Claude Code)")")
        if let model = WhisperRefiner.preferredModel() {
            let size = (try? FileManager.default.attributesOfItem(atPath: model.path)[.size] as? Int) ?? 0
            print("Whisper model  : \(model.lastPathComponent) (\(size / 1_000_000) MB)")
        } else {
            print("Whisper model  : NOT FOUND (run Scripts/fetch-model.sh)")
        }
        // Count readable meetings, not directory entries — a stray .DS_Store
        // was being counted as a meeting.
        print("Meetings stored: \(MeetingStore.loadIndex().count)")

        // Same mapping the Settings pane shows, so the two cannot disagree.
        let mic = PermissionsService.status(from: AVCaptureDevice.authorizationStatus(for: .audio))
        // Caveat worth printing: when this binary is launched from a shell, TCC
        // attributes the request to the terminal, not to Minutes.app. So this
        // can read Granted while the app itself is denied. The app's own
        // Settings > Permissions pane is authoritative.
        await printClaudeConnection()
        print("Microphone     : \(mic.label)  (as \(launchContext()))")
        print("Calendar       : \(PermissionsService.calendarStatus().label)")
        print("Audio Recording: not readable via any API — use Settings › Permissions › Test now,")
        print("                 or `--test-capture 4` and check the peak system level")
    }

    /// Reuses the same parser the Settings pane uses, so the two cannot drift.
    /// `claude auth status` costs no tokens.
    private static func printClaudeConnection() async {
        guard let binary = ToolLocator.find("claude") else {
            print("Claude         : CLI NOT FOUND")
            return
        }
        do {
            let output = try await Shell.run(executable: binary,
                                            arguments: ["auth", "status"],
                                            environment: ToolLocator.enrichedEnvironment(),
                                            currentDirectory: AppPaths.supportRoot,
                                            timeout: 20)
            guard let status = ClaudeConnection.parseAuthStatus(output.standardOutput) else {
                print("Claude         : could not read auth status")
                return
            }
            if status.loggedIn {
                let detail = [status.account.email, status.account.organization,
                              status.account.subscription, status.account.authMethod]
                    .compactMap { $0 }.joined(separator: " · ")
                print("Claude         : signed in (\(detail))")
            } else {
                print("Claude         : SIGNED OUT — run `claude auth login`")
            }
        } catch {
            print("Claude         : check failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Ask

    /// Puts a question to the library from the command line, streaming the reply.
    static func ask(_ question: String?) async {
        guard let question, !question.trimmingCharacters(in: .whitespaces).isEmpty else {
            print("usage: --ask \"your question\"")
            return
        }

        let meetings = MeetingStore.loadAll()
        print("Asking across \(meetings.count) meeting\(meetings.count == 1 ? "" : "s")…")
        print("")

        // Print deltas as they arrive; onDelta carries the whole text so far, so
        // only the new tail is emitted.
        let printed = TextProgress()
        do {
            let answer = try await MeetingChatService().ask(
                question: question,
                history: [],
                meetings: meetings,
                onDelta: { partial in printed.emit(partial) })

            printed.emit(answer.text)
            print("")
            print("")
            if answer.groundedIn.isEmpty {
                print("(no meeting notes were included — the index alone was used)")
            } else {
                print("(grounded in \(answer.groundedIn.count) meeting\(answer.groundedIn.count == 1 ? "" : "s"))")
            }
        } catch {
            print("")
            print("FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompt

    /// Puts the detection prompt on screen so it can be looked at without
    /// joining a call, and reports the size it settled on.
    ///
    /// Runs the run loop directly rather than through `runBlocking`: SwiftUI
    /// cannot lay the panel out unless the main thread is pumping events, and
    /// `runBlocking` parks it on a semaphore.
    @MainActor
    private static func testPrompt() {
        print("Showing the meeting prompt for 6 seconds…")
        print("Note: this checks the panel's size, not its placement. The menu bar")
        print("item belongs to the running app and does not exist in this process,")
        print("so the prompt falls back to the top-right corner here. To see it")
        print("anchored under the icon, use Settings › General › Preview the prompt.")

        MeetingPromptPanel.shared.show(appName: "Microsoft Teams",
                                       ambiguous: false,
                                       onRecord: { print("  -> Record was clicked") },
                                       onIgnore: { print("  -> Not now was clicked") })
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        MeetingPromptPanel.shared.hide()
        print("Done. Size and position are in the log lines above.")
    }

    // MARK: - Start latency

    /// Measures click-to-capture: how long the audio engine takes to open both
    /// sources. Run twice, because the first start of a session pays hardware
    /// spin-up the second does not.
    static func timeStart() async {
        for attempt in 1...2 {
            let url = AppPaths.supportRoot.appendingPathComponent("timing-test.wav")
            let engine = AudioCaptureEngine()
            let began = Date()
            do {
                try engine.start(writingTo: url, captureMic: true, captureSystem: true)
            } catch {
                print("start #\(attempt) FAILED: \(error.localizedDescription)")
                continue
            }
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            // Long enough for the slower source to attach, so stop() reports both.
            try? await Task.sleep(for: .milliseconds(800))
            _ = engine.stop()
            try? FileManager.default.removeItem(at: url)
            print("start #\(attempt): \(ms)ms to first source capturing (others attach behind it)")
        }
    }

    // MARK: - Detection

    /// Shows what meeting detection can currently see, which is the fastest way
    /// to tell a missing bundle identifier from an app that simply is not
    /// holding the microphone.
    /// Prints every change in who holds the microphone, live, for a while —
    /// for checking a real call end to end: join it, watch the lines.
    ///
    /// Every process is listed, recognised or not, because the question this
    /// answers is usually "what is the call app actually called": a FaceTime
    /// or phone call may run its audio through a system process, and a new
    /// Teams or Zoom build can ship a helper under a new identifier. A browser
    /// line also says which meeting its front tab is in, when Accessibility
    /// allows reading it from here.
    static func watchDetection(for seconds: TimeInterval) async {
        print("Watching the microphone for \(Int(seconds)) s — join a call now. Ctrl-C to stop.")
        print("A recognised app holding input for two polls (about 6 s) is a detected call.")
        if !CallWindowTitle.isTrusted {
            print("(Browser tabs can't be read from this terminal: Accessibility is granted to the app, not to Terminal.)")
        }
        var previous: [String: String] = [:]
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            var current: [String: String] = [:]
            for row in MeetingDetector.snapshot() where row.isRunningInput {
                var description = row.matchedApp.map { $0 + (row.isAmbiguous ? " (browser)" : "") } ?? "unrecognised"
                if row.isAmbiguous, let app = row.matchedApp {
                    let detection = MeetingDetector.Detection(bundleID: row.bundleID, appName: app, isAmbiguous: true)
                    if let match = BrowserMeeting.current(for: detection) {
                        description += " → \(match.service)" + (match.name.map { " “\($0)”" } ?? "")
                    }
                }
                current[row.bundleID] = description
            }
            let stamp = Formats.time(Date())
            for (id, description) in current where previous[id] != description {
                print("\(stamp)  + \(id)  \(description)")
            }
            for id in previous.keys where current[id] == nil {
                print("\(stamp)  − \(id)  released the microphone")
            }
            previous = current
            try? await Task.sleep(for: .seconds(1.5))
        }
        print("Done.")
    }

    static func testDetection() async {
        print("Meeting detection snapshot")
        print("--------------------------")
        let rows = MeetingDetector.snapshot()
        let interesting = rows.filter { $0.isRunningInput || $0.matchedApp != nil }

        if interesting.isEmpty {
            print("No conferencing app is known to Core Audio, and nothing is capturing input.")
        } else {
            // %s in String(format:) expects a C string; passing Swift Strings
            // there prints garbage or traps. Pad by hand instead.
            func pad(_ text: String, _ width: Int) -> String {
                text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
            }
            print(pad("INPUT", 7) + pad("OUTPUT", 8) + pad("MATCH", 18) + "BUNDLE ID")
            for row in interesting.sorted(by: { $0.bundleID < $1.bundleID }) {
                let match = row.matchedApp.map { $0 + (row.isAmbiguous ? " (?)" : "") } ?? "-"
                print(pad(row.isRunningInput ? "YES" : "no", 7)
                      + pad(row.isRunningOutput ? "YES" : "no", 8)
                      + pad(match, 18) + row.bundleID)
            }
        }

        print("")
        if let detection = MeetingDetector.currentDetection() {
            print("Would prompt to record: \(detection.appName)"
                  + (detection.isAmbiguous ? " (ambiguous — browsers ask unless a calendar meeting link is current)" : ""))
        } else {
            print("Would not prompt: no known conferencing app is capturing audio input.")
        }
        print("")
        print("Total processes seen by Core Audio: \(rows.count)")
        print("A meeting is detected when a known app reports INPUT=YES for two")
        print("consecutive polls (about six seconds).")
    }

    // MARK: - Selftest

    static func selftest(audioPath: String?) async {
        await doctor()
        print("")

        guard let audioPath else {
            print("error: --selftest needs a path to a .wav file")
            return
        }
        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("error: no file at \(url.path)")
            return
        }

        print("Transcribing \(url.lastPathComponent) with Whisper…")
        var refiner = WhisperRefiner()
        refiner.onProgress = { value in
            if Int(value * 100) % 25 == 0 { print("  \(Int(value * 100))%") }
        }

        let segments: [TranscriptSegment]
        do {
            segments = try await refiner.transcribe(audioFile: url, energy: EnergyTrack())
        } catch {
            print("TRANSCRIPTION FAILED: \(error.localizedDescription)")
            return
        }

        print("")
        print("Transcript (\(segments.count) segments)")
        print("---------------------------")
        for segment in segments {
            print("[\(segment.timestampLabel)] \(segment.speaker.label): \(segment.text)")
        }

        var meeting = Meeting(title: "Selftest meeting", startedAt: Date())
        meeting.endedAt = Date().addingTimeInterval(segments.last?.end ?? 60)
        meeting.segments = segments
        meeting.notes = "- checking that the pipeline works end to end"

        print("")
        print("Summarizing with Claude (\(AppSettings.shared.claudeModel))…")
        do {
            let summary = try await ClaudeSummarizer().summarize(meeting: meeting, template: .general).notes
            print("")
            print("Summary")
            print("---------------------------")
            print(summary)
            print("")
            print("SELFTEST PASSED")
        } catch {
            print("SUMMARIZATION FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Capture test

    static func testCapture(seconds: Double) async {
        // This runs before NSApplication exists, so a TCC prompt cannot be
        // displayed and requesting access would block forever. Check instead, and
        // tell the user to grant it by launching the app itself.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            print("Microphone permission is \(micStatus == .notDetermined ? "not yet requested" : "denied").")
            print("Launch Minutes.app and start a recording once to grant it, then re-run this test.")
            print("Continuing with system audio only…")
        }

        print("Recording \(Int(seconds))s to verify audio capture…")
        let url = AppPaths.supportRoot.appendingPathComponent("capture-test.wav")
        let engine = AudioCaptureEngine()

        do {
            try engine.start(writingTo: url,
                             captureMic: micStatus == .authorized,
                             captureSystem: true)
        } catch {
            print("CAPTURE FAILED: \(error.localizedDescription)")
            return
        }

        try? await Task.sleep(for: .seconds(seconds))
        let result = engine.stop()

        print("")
        print("Microphone captured : \(result.capturedMic ? "yes" : "no")")
        print("System audio captured: \(result.capturedSystem ? "yes" : "no")")
        if let reason = result.degradedReason { print("Note: \(reason)") }
        print("Duration written    : \(String(format: "%.2f", result.duration))s")
        print("Peak mic level      : \(String(format: "%.4f", result.peakMicLevel))")
        print("Peak system level   : \(String(format: "%.4f", result.peakSystemLevel))")
        print("Energy frames       : \(result.energy.frames.count)")
        print("Buffers from mic    : \(result.micBuffersReceived) -> \(result.micSamplesResampled) samples")
        print("Buffers from system : \(result.systemBuffersReceived) -> \(result.systemSamplesResampled) samples")
        print("File                : \(url.path)")

        if result.duration < seconds * 0.5 {
            print("")
            print("WARNING: far less audio was written than expected.")
        } else {
            print("")
            print("CAPTURE TEST PASSED")
        }
    }
}


/// Emits only the newly arrived tail of a streamed reply.
private final class TextProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var shown = ""

    func emit(_ full: String) {
        lock.lock()
        guard full.count > shown.count, full.hasPrefix(shown) else {
            // A final text that is not an extension of what streamed: print the
            // remainder rather than nothing.
            if full != shown {
                shown = full
                lock.unlock()
                FileHandle.standardOutput.write(Data("\n".utf8))
                return
            }
            lock.unlock()
            return
        }
        let tail = String(full.dropFirst(shown.count))
        shown = full
        lock.unlock()
        FileHandle.standardOutput.write(Data(tail.utf8))
    }
}


extension Diagnostics {
    /// Speaks through the speakers while listening on the microphone, once
    /// without echo cancellation and once with it, and reports how much of the
    /// speech the microphone picked up each time.
    ///
    /// Must run as the app for microphone permission:
    ///   open -a Minutes --args --test-echo
    /// Results go to the log and to echo-test.txt in the support folder.
    static func testEcho() async {
        guard await MicCapture.requestAccess() else {
            report("Echo test: microphone access is not granted to Minutes.")
            return
        }
        var lines = ["Echo test — speech played through the speakers, measured at the microphone"]
        var levels: [Bool: Double] = [:]
        for cancel in [false, true] {
            let meter = LevelBox()
            let mic = MicCapture(echoCancellation: cancel)
            do {
                try mic.start { buffer, _ in meter.add(buffer) }
            } catch {
                lines.append("  \(cancel ? "with" : "without") cancellation: microphone failed (\(error.localizedDescription))")
                continue
            }
            try? await Task.sleep(for: .milliseconds(600))   // let voice processing settle
            meter.reset()
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-r", "190", "Testing echo cancellation. This sentence is played through the speakers, and the microphone should not hear it."]
            try? say.run()
            say.waitUntilExit()
            mic.stop()
            let db = meter.dBFS
            levels[cancel] = db
            lines.append(String(format: "  %@ cancellation: microphone heard the speakers at %.1f dBFS%@",
                                cancel ? "with   " : "without", db,
                                cancel && !mic.echoCancellationActive ? " (voice processing did NOT engage)" : ""))
        }
        if let off = levels[false], let on = levels[true] {
            let reduction = off - on
            lines.append(String(format: "  Reduction: %.1f dB — %@", reduction,
                                reduction >= 15 ? "echo cancellation is working."
                                : reduction >= 6 ? "partial; headphones are still better."
                                : "little effect; check the output device, or use headphones."))
        }
        report(lines.joined(separator: "\n"))
    }

    private static func report(_ text: String) {
        print(text)
        Log.info(text)
        try? text.write(to: AppPaths.supportRoot.appendingPathComponent("echo-test.txt"),
                        atomically: true, encoding: .utf8)
    }
}

/// Accumulates RMS across microphone buffers from the audio thread.
private final class LevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sumSquares: Double = 0
    private var count = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        var sum: Double = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for i in 0..<frames { let v = Double(channels[channel][i]); sum += v * v }
        }
        lock.lock(); sumSquares += sum; count += frames * Int(buffer.format.channelCount); lock.unlock()
    }

    func reset() { lock.lock(); sumSquares = 0; count = 0; lock.unlock() }

    var dBFS: Double {
        lock.lock(); defer { lock.unlock() }
        guard count > 0 else { return -120 }
        return 20 * log10(max((sumSquares / Double(count)).squareRoot(), 1e-6))
    }
}


extension Diagnostics {
    /// Tries voice processing in several engine configurations, each on a fresh
    /// AVAudioEngine, and reports which start and how loud speaker playback is
    /// at the microphone in each. Development aid for echo cancellation.
    static func probeVoiceProcessing() async {
        guard await MicCapture.requestAccess() else { report("probe: no mic access"); return }
        struct Variant { let name: String; let setup: (AVAudioEngine) throws -> AVAudioFormat? }
        let variants: [Variant] = [
            Variant(name: "raw mic (no VP)") { _ in nil },
            Variant(name: "VP, tap node format") { e in
                try e.inputNode.setVoiceProcessingEnabled(true); return nil },
            Variant(name: "VP, tap mono") { e in
                try e.inputNode.setVoiceProcessingEnabled(true)
                return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: e.inputNode.outputFormat(forBus: 0).sampleRate,
                                     channels: 1, interleaved: false) },
            Variant(name: "VP, mixer muted, tap mono") { e in
                try e.inputNode.setVoiceProcessingEnabled(true)
                e.mainMixerNode.outputVolume = 0
                return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: e.inputNode.outputFormat(forBus: 0).sampleRate,
                                     channels: 1, interleaved: false) },
            Variant(name: "VP, input->mixer muted, tap mono") { e in
                try e.inputNode.setVoiceProcessingEnabled(true)
                let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: e.inputNode.outputFormat(forBus: 0).sampleRate,
                                         channels: 1, interleaved: false)
                e.connect(e.inputNode, to: e.mainMixerNode, format: mono)
                e.mainMixerNode.outputVolume = 0
                return mono },
            Variant(name: "outputNode first, VP, tap mono") { e in
                _ = e.outputNode
                try e.inputNode.setVoiceProcessingEnabled(true)
                return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: e.inputNode.outputFormat(forBus: 0).sampleRate,
                                     channels: 1, interleaved: false) },
        ]
        var lines = ["Voice processing probe"]
        for variant in variants {
            let engine = AVAudioEngine()
            let meter = LevelBox()
            do {
                let tapFormat = try variant.setup(engine)
                let node = engine.inputNode
                let reported = node.outputFormat(forBus: 0)
                try node.installAudioTap(onBus: 0, bufferSize: 4096, format: tapFormat ?? reported) { buffer, _ in
                    meter.add(AVAudioPCMBuffer(copying: buffer))
                }
                engine.prepare()
                try engine.start()
                try? await Task.sleep(for: .milliseconds(700))
                meter.reset()
                let say = Process()
                say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                say.arguments = ["-r", "220", "One two three four five six seven."]
                try? say.run(); say.waitUntilExit()
                lines.append(String(format: "  OK   %@ — node %d ch, speakers at mic %.1f dBFS",
                                    variant.name, reported.channelCount, meter.dBFS))
            } catch {
                lines.append("  FAIL \(variant.name) — \((error as NSError).code)")
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            try? await Task.sleep(for: .milliseconds(300))
        }
        report(lines.joined(separator: "\n"))
    }
}
