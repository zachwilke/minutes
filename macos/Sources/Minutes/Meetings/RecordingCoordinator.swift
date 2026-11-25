import Foundation
import Combine
import AppKit

/// The app's brain: owns the capture session and drives each meeting through
/// record → transcribe → summarize, keeping the UI informed at every step.
@MainActor
final class RecordingCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case failed(String)

        var isRecording: Bool { self == .recording }
    }

    /// Which pipeline stage a meeting is in after its recording ended.
    enum Pipeline: Equatable {
        case transcribing(progress: Double)
        case summarizing
    }

    /// Recording lifecycle only. Transcription and summarization are tracked
    /// per meeting in `processing`, deliberately not here: with them folded into
    /// one phase, the record button was dead for the minutes a long meeting
    /// spent in Whisper — and accepting a detection prompt during that window
    /// silently did nothing. Back-to-back meetings are the normal workday, so a
    /// new recording must never wait on the previous meeting's pipeline.
    @Published private(set) var phase: Phase = .idle
    /// Meetings currently being transcribed or summarized.
    @Published private(set) var processing: [UUID: Pipeline] = [:]
    @Published private(set) var activeMeetingID: UUID?
    /// Levels, clock and live text live on their own object so their update rate
    /// does not set the render rate of everything observing this coordinator.
    let activity = RecordingActivity()
    /// A detected meeting awaiting the user's go-ahead.
    @Published var pendingDetection: MeetingDetector.Detection?
    /// Non-fatal warning about the current recording, e.g. system audio blocked.
    @Published private(set) var warning: String?
    /// So a full disk is reported once per recording, not on every level tick.
    private var reportedWriteFailure = false
    /// Set by the menu bar popover to ask the window to show a meeting; the
    /// window consumes and clears it.
    @Published var requestedMeetingID: UUID?
    /// Same, for a sidebar item that is not a meeting — the chat, for a brief
    /// started from the menu bar.
    @Published var requestedSidebarItem: SidebarItem?

    let store: MeetingStore
    let detector = MeetingDetector()
    let reminders = MeetingReminders()

    private var engine: AudioCaptureEngine?
    private var transcriber: LiveTranscriber?
    private var elapsedTimer: Timer?
    /// The call this recording belongs to: the detection that started it, or a
    /// call joined shortly after a manual start. Its end stops the recording.
    private var recordingApp: MeetingDetector.Detection?
    private var recordingStartedAt: Date?
    /// Started by detection rather than a click — the only recordings that
    /// may be thrown away as false starts.
    private var recordingWasAutomatic = false

    /// An automatic recording whose call ends within this, with nothing typed,
    /// was a microphone blip — a device test, a call declined while ringing —
    /// not a meeting. Library entries like "Teams call, 13:51 · 24s" are what
    /// keeping them looked like.
    nonisolated static let falseStartLimit: TimeInterval = 45
    /// Feeds mixed audio to the live transcriber in order; finished at stop.
    private var chunkSink: AsyncStream<[Float]>.Continuation?
    private var chunkConsumer: Task<Void, Never>?
    /// Last moment either source carried more than background noise.
    private var lastSoundAt = Date()
    private var sleepObserver: NSObjectProtocol?

    /// A call left this long without a sound is over, whatever the app says —
    /// someone walked away with the meeting window open. Granola uses the same.
    private static let silenceLimit: TimeInterval = 15 * 60
    /// RMS above this counts as sound. Speech is roughly 0.02–0.2 and a quiet
    /// room's noise floor well under 0.005; erring low only delays a stop.
    private static let soundThreshold: Float = 0.008
    /// A manual recording adopts a call that starts within this window — you hit
    /// Record, then join. Later calls are someone else's business.
    private static let adoptionWindow: TimeInterval = 120
    /// True across the awaits in `startRecording`. `phase` only becomes
    /// `.recording` once capture is live, so without this a second click — or a
    /// detection accepted mid-start — started a second engine whose meeting
    /// could never be stopped.
    private var isStarting = false

    /// The app delegate needs to reach the recorder at quit time, and it is not
    /// part of the SwiftUI environment.
    private(set) static weak var current: RecordingCoordinator?

    init(store: MeetingStore) {
        self.store = store
        configureDetector()
        configureNotificationRouting()
        Self.current = self
        resumeInterruptedPipelines()
        observeSleep()
        configureReminders()
        backfillTitlesOnce()
    }

    // MARK: - Titles

    /// Once: tidy raw call-window titles left by older builds — "Acme Status
    /// Call | Example Corp | you@example.com" into "Acme Status Call".
    /// Pure string work; nothing is sent to Claude. Meetings still carrying a
    /// placeholder are named the next time their notes are written.
    private func backfillTitlesOnce() {
        guard !AppSettings.shared.titlesBackfilled else { return }
        Task { [weak self] in
            // Out of the way of launch.
            try? await Task.sleep(for: .seconds(8))
            guard let self else { return }
            var cleaned = 0
            for meeting in self.store.meetings where meeting.title.contains(" | ") {
                let tidy = MeetingTitle.fromWindow(meeting.title) ?? ""
                guard tidy != meeting.title else { continue }
                self.store.update(id: meeting.id) { $0.title = tidy }
                cleaned += 1
            }
            AppSettings.shared.titlesBackfilled = true
            Log.info("Title backfill: cleaned \(cleaned) window titles")
        }
    }

    private func configureReminders() {
        reminders.onReminder = { [weak self] event in
            guard let self, !self.phase.isRecording else { return }
            if NotificationPresenter.canDeliver {
                NotificationPresenter.meetingStartingSoon(event)
            } else {
                MeetingPromptPanel.shared.showReminder(event) { [weak self] in
                    self?.joinAndRecord(title: event.title, link: event.meetingLink)
                }
            }
        }
        calendarSettingChanged()
    }

    /// Starts or stops the calendar-driven parts when Calendar is switched.
    func calendarSettingChanged() {
        if AppSettings.shared.calendarEnabled { reminders.start() } else { reminders.stop() }
    }

    /// Opens the call and records it. Recording starts before the call has
    /// connected; the call's app grabbing the microphone a moment later is
    /// adopted by this recording, so it stops when the call ends.
    func joinAndRecord(title: String, link: URL?) {
        if let link {
            NSWorkspace.shared.open(link)
        }
        guard !phase.isRecording else { return }
        Task { await startRecording(title: title) }
    }

    /// A sleeping Mac captures nothing, and a recording resumed hours later
    /// would stitch two unrelated stretches together.
    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase.isRecording else { return }
                Log.info("Stopping recording because the Mac is going to sleep")
                await self.stopRecording()
            }
        }
    }

    /// Picks up meetings whose transcription or summary was cut off by a quit or
    /// crash. A meeting that already has its transcript only needs the summary.
    private func resumeInterruptedPipelines() {
        for id in store.interruptedPipelines {
            guard let meeting = store.meeting(id: id) else { continue }
            Log.info("Resuming interrupted pipeline for \(id) (\(meeting.state))")
            if meeting.state == .summarizing, meeting.hasSegments {
                pipelineTask = Task { [previous = pipelineTask] in
                    await previous?.value
                    await self.summarize(meetingID: id)
                }
            } else {
                enqueuePipeline(meetingID: id, energy: nil)
            }
        }
    }

    /// Connects the buttons on a notification banner to this coordinator. Set up
    /// here rather than in the App struct so the wiring lives next to the actions
    /// it triggers.
    private func configureNotificationRouting() {
        let router = NotificationRouter.shared
        router.onRecordRequested = { [weak self] in self?.acceptPendingDetection() }
        router.onIgnoreRequested = { [weak self] in self?.dismissPendingDetection() }
        router.onStopRequested = { [weak self] in Task { await self?.stopRecording() } }
        router.onDiscardRequested = { [weak self] in Task { await self?.discardRecording() } }
        router.onJoinRequested = { [weak self] title, link in self?.joinAndRecord(title: title, link: link) }
        router.onOpenRequested = {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var activeMeeting: Meeting? {
        activeMeetingID.flatMap { store.meeting(id: $0) }
    }

    // MARK: - Detection

    private func configureDetector() {
        detector.onMeetingStarted = { [weak self] detection in
            self?.callStarted(detection)
        }
        detector.onMeetingEnded = { [weak self] detection in
            self?.callEnded(detection)
        }
        if AppSettings.shared.autoDetectMeetings {
            detector.start()
        }
    }

    private func callStarted(_ detection: MeetingDetector.Detection) {
        guard AppSettings.shared.autoDetectMeetings else { return }

        if phase.isRecording || isStarting {
            // You pressed Record, then joined: the call is this recording's.
            if recordingApp == nil, let started = recordingStartedAt,
               Date().timeIntervalSince(started) < Self.adoptionWindow {
                recordingApp = detection
                Log.info("Recording adopted \(detection.appName) call")
                // Pressed Record, then joined: the call's name is still the
                // best one available, and the click gave none.
                if let id = activeMeetingID, let meeting = store.meeting(id: id),
                   meeting.calendarEventTitle == nil, MeetingTitle.isPlaceholder(meeting.title),
                   AppSettings.shared.nameFromCallWindow {
                    nameFromCallWindow(meetingID: id, detection: detection, defaultTitle: meeting.title)
                }
            } else {
                // Not dropped: the detector keeps it, and it is offered when the
                // current recording ends — back-to-back calls each get their own.
                Log.info("\(detection.appName) call detected while recording; offering it afterwards")
            }
            return
        }
        handle(detection)
    }

    private func callEnded(_ detection: MeetingDetector.Detection) {
        if pendingDetection?.key == detection.key {
            // The question is moot once the call is over.
            pendingDetection = nil
            MeetingPromptPanel.shared.hide()
            NotificationPresenter.clearMeetingPrompt()
        }
        guard phase.isRecording, recordingApp?.key == detection.key else { return }
        if isFalseStart {
            Log.info("\(detection.appName) released the microphone within \(Int(Self.falseStartLimit)) s of an automatic start; discarding it")
            Task { await self.discardFalseStart() }
            return
        }
        Log.info("Auto-stopping recording because \(detection.appName) left the call")
        Task { await self.stopRecording() }
    }

    /// Records, or offers to.
    ///
    /// A call that is on the calendar records by itself — it was planned, and
    /// the notes are expected. A call that is not gets an offer: impromptu
    /// calls include the ones nobody wants recorded, so the first move there
    /// is the user's. Without calendar access nothing counts as scheduled, so
    /// every call is offered. "Always ask" offers everything.
    ///
    /// A browser is first checked for which meeting its tab is in, so a Meet
    /// call is offered as a Google Meet call, not "Chrome is using your
    /// microphone"; an unrecognised browser is always offered, and only records
    /// by itself during an event with a join link.
    private func handle(_ detection: MeetingDetector.Detection) {
        // EKEventStore and Accessibility reads can stall, so off the main actor.
        Task {
            let (resolved, event) = await Task.detached(priority: .userInitiated) { () -> (MeetingDetector.Detection, CalendarService.Event?) in
                var resolved = detection
                if detection.isAmbiguous, let match = BrowserMeeting.current(for: detection) {
                    resolved.service = match.service
                }
                return (resolved, CalendarService.shared.currentEvent())
            }.value
            // The call may have ended, or another started recording, meanwhile.
            guard detector.isInCall(detection.key), !phase.isRecording, !isStarting,
                  pendingDetection == nil else { return }

            if Self.recordsAutomatically(resolved, mode: AppSettings.shared.detectionMode,
                                         eventHasLink: event.map { $0.meetingLink != nil }) {
                Log.info("\(resolved.displayName) call during “\(event?.title ?? "")”; recording automatically")
                await startRecording(detection: resolved, automatic: true)
            } else {
                Log.info("\(resolved.displayName) call \(event == nil ? "with nothing on the calendar" : "during an event"); offering to record")
                ask(about: resolved)
            }
        }
    }

    private func ask(about detection: MeetingDetector.Detection) {
        pendingDetection = detection
        // A banner is the nicer prompt, but it is not guaranteed: with
        // notification permission denied the app would detect a call and then
        // say nothing. Fall back to the floating panel in that case, so the
        // prompt always actually appears.
        if NotificationPresenter.canDeliver {
            NotificationPresenter.meetingDetected(appName: detection.displayName,
                                                  ambiguous: !detection.isRecognisedMeeting)
        } else {
            MeetingPromptPanel.shared.show(
                appName: detection.displayName,
                ambiguous: !detection.isRecognisedMeeting,
                onRecord: { [weak self] in self?.acceptPendingDetection() },
                onIgnore: { [weak self] in self?.dismissPendingDetection() })
        }
    }

    /// Once the recorder is free, the next call still in progress gets its turn.
    private func offerNextCall() {
        guard AppSettings.shared.autoDetectMeetings, !phase.isRecording, !isStarting,
              pendingDetection == nil,
              let next = detector.unhandledCalls.first else { return }
        Log.info("Offering \(next.appName) call, still in progress")
        handle(next)
    }

    func setDetectionEnabled(_ enabled: Bool) {
        AppSettings.shared.autoDetectMeetings = enabled
        if enabled { detector.start() } else { detector.stop() }
    }

    func acceptPendingDetection() {
        guard let detection = pendingDetection else { return }
        pendingDetection = nil
        MeetingPromptPanel.shared.hide()
        NotificationPresenter.clearMeetingPrompt()
        Task { await startRecording(detection: detection) }
    }

    func dismissPendingDetection() {
        if let key = pendingDetection?.key { detector.suppress(key) }
        pendingDetection = nil
        MeetingPromptPanel.shared.hide()
        NotificationPresenter.clearMeetingPrompt()
    }

    /// The rule `handle` applies, on its own so it can be tested.
    /// `eventHasLink` is nil when no meeting is on the calendar right now.
    nonisolated static func recordsAutomatically(_ detection: MeetingDetector.Detection,
                                                 mode: DetectionMode, eventHasLink: Bool?) -> Bool {
        guard mode == .autoRecord, let eventHasLink else { return false }
        // A dedicated app or a recognised meeting tab during a meeting is that
        // meeting; an unrecognised browser needs the event's join link to say so.
        return detection.isRecognisedMeeting || eventHasLink
    }

    /// Whether the recording now ending was a microphone blip: started by
    /// detection, short, and nothing typed into it.
    private var isFalseStart: Bool {
        Self.isFalseStart(automatic: recordingWasAutomatic,
                          duration: recordingStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity,
                          notes: activeMeeting?.notes ?? "")
    }

    nonisolated static func isFalseStart(automatic: Bool, duration: TimeInterval, notes: String) -> Bool {
        automatic && duration < falseStartLimit
            && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Like Discard, but for a call that has already ended: nothing is
    /// suppressed, because the next call in that app is a new one and must
    /// still be detected.
    private func discardFalseStart() async {
        guard phase.isRecording, let meetingID = activeMeetingID else { return }
        await stopRecording(startPipeline: false, offerNext: false)
        if let meeting = store.meeting(id: meetingID) { store.delete(meeting) }
        // Its "Recording your call" notice would otherwise outlive it.
        NotificationPresenter.clearAutoRecordingNotice()
        MeetingPromptPanel.shared.hide()
        warning = nil
        offerNextCall()
    }

    /// Stops and deletes the current recording — the undo for an automatic
    /// start. The call stays suppressed, so it is not offered again.
    func discardRecording() async {
        guard phase.isRecording, let meetingID = activeMeetingID else { return }
        if let key = recordingApp?.key { detector.suppress(key) }
        await stopRecording(startPipeline: false, offerNext: false)
        if let meeting = store.meeting(id: meetingID) {
            store.delete(meeting)
            Log.info("Discarded recording \(meetingID)")
        }
        warning = nil
        offerNextCall()
    }

    // MARK: - Recording

    /// `automatic` marks a start nobody clicked for; it is announced with Stop
    /// and Discard rather than a plain "Recording" notice.
    func startRecording(detection: MeetingDetector.Detection? = nil,
                        title: String? = nil,
                        automatic: Bool = false) async {
        guard !phase.isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        if case .failed = phase { phase = .idle }
        let clicked = Date()

        // Ask for the microphone up front; without it we would silently record
        // only the far end of the call. When access is already settled this is a
        // synchronous status read, not a prompt, so it costs nothing.
        if AppSettings.shared.captureMicrophone, await MicCapture.requestAccess() == false {
            phase = .failed("Minutes needs microphone access. Grant it in System Settings › Privacy & Security › Microphone.")
            return
        }

        // Nothing but the hardware sits on the critical path from here to
        // capture. The meeting is built in memory; the disk write, the calendar
        // lookup and live transcription all happen after audio is flowing —
        // none of them can capture the words being spoken right now, and the
        // recorder can.
        var meeting = Meeting(title: title ?? Self.defaultTitle(for: detection),
                              startedAt: Date())
        meeting.detectedAppBundleID = detection?.bundleID
        meeting.detectedAppName = detection?.appName
        meeting.templateID = AppSettings.shared.defaultTemplateID
        meeting.state = .recording

        let engine = AudioCaptureEngine()
        let transcriber = LiveTranscriber()

        engine.onLevels = { [weak self] levels in
            Task { @MainActor in
                guard let self else { return }
                self.activity.levels = levels
                if max(levels.mic, levels.system) > Self.soundThreshold { self.lastSoundAt = Date() }
                if levels.writeFailed, !self.reportedWriteFailure {
                    self.reportedWriteFailure = true
                    self.warning = "Your disk is full, so the rest of this recording isn't being saved. "
                        + "Free up some space — what was recorded before now is kept."
                }
            }
        }
        // One consumer, in order. A Task per chunk carries no ordering
        // guarantee, so chunks could reach the transcriber shuffled — and the
        // last ones after it had finished.
        let (chunks, chunkSink) = AsyncStream<[Float]>.makeStream()
        engine.onMixedChunk = { samples in chunkSink.yield(samples) }
        self.chunkSink = chunkSink
        self.chunkConsumer = Task {
            for await samples in chunks { await transcriber.append(samples) }
        }

        do {
            // Starting capture blocks: Core Audio builds an aggregate device and
            // AVAudioEngine may sit waiting on a permission decision. Doing that
            // on the main actor would freeze the window, so it runs off-thread.
            let audioFile = meeting.mixedAudioFile
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try engine.start(writingTo: audioFile)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            Log.error("Capture failed to start: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            var failed = meeting
            failed.state = .failed
            failed.failureReason = error.localizedDescription
            failed.endedAt = Date()
            store.save(failed)
            return
        }

        self.engine = engine
        self.transcriber = transcriber
        self.activeMeetingID = meeting.id
        // A manual start during a call that is already running belongs to it.
        self.recordingApp = detection ?? detector.callsInProgress.first
        self.recordingStartedAt = Date()
        self.lastSoundAt = Date()
        self.lastEnergyCheckpoint = Date()
        self.pendingDetection = nil
        MeetingPromptPanel.shared.hide()
        NotificationPresenter.clearMeetingPrompt()
        self.activity.reset()
        self.warning = Self.lowDiskWarning()
        self.reportedWriteFailure = false
        self.recordingWasAutomatic = automatic
        self.phase = .recording
        Log.info("Recording live \(Int(Date().timeIntervalSince(clicked) * 1000))ms after click")

        store.save(meeting)

        // Naming is cosmetic and EKEventStore and Accessibility queries can
        // stall, so the title is applied retroactively rather than making the
        // click wait. The calendar wins — it also brings the invitees — and the
        // call's window title covers calls the calendar does not know about.
        let meetingID = meeting.id
        let defaultTitle = meeting.title
        let namedByCaller = title != nil
        if AppSettings.shared.calendarEnabled {
            Task.detached(priority: .utility) { [weak self] in
                guard let event = CalendarService.shared.currentEvent() else { return }
                await MainActor.run { [weak self] in
                    self?.store.update(id: meetingID) { current in
                        current.calendarEventTitle = event.title
                        // The style this series was last written in, if one was chosen.
                        if let remembered = AppSettings.shared.template(forSeries: event.title),
                           SummaryTemplate.all.contains(where: { $0.id == remembered }) {
                            current.templateID = remembered
                        }
                        current.attendees = event.attendees
                        current.attendeeEmails = event.attendeeEmails
                        // Not over a name the user has typed meanwhile.
                        if !namedByCaller, current.title == defaultTitle, !event.title.isEmpty {
                            current.title = event.title
                        }
                    }
                }
            }
        }
        // The call this recording belongs to: the one that started it, or one
        // already in progress when Record was pressed.
        if let call = detection ?? recordingApp, AppSettings.shared.nameFromCallWindow, !namedByCaller {
            nameFromCallWindow(meetingID: meetingID, detection: call, defaultTitle: defaultTitle)
        }

        // Live transcription is a convenience; a failure here must not stop the
        // recording, because Whisper will still produce the real transcript.
        Task { [weak self] in
            do {
                try await transcriber.start { [weak self] text in
                    Task { @MainActor in self?.activity.liveText = text }
                }
            } catch LiveTranscriptionError.abandoned {
                return
            } catch {
                Log.warn("Live transcription unavailable: \(error.localizedDescription)")
                await MainActor.run {
                    self?.warning = "Live text is unavailable (\(error.localizedDescription)) — the full transcript will still be produced when you stop."
                }
            }
        }

        startElapsedTimer()
        if automatic, let detection {
            Log.info("Recording started automatically for \(detection.displayName)")
            if NotificationPresenter.canDeliver {
                NotificationPresenter.autoRecordingStarted(appName: detection.displayName)
            } else {
                MeetingPromptPanel.shared.showAutoRecording(
                    appName: detection.displayName,
                    onStop: { [weak self] in Task { await self?.stopRecording() } },
                    onDiscard: { [weak self] in Task { await self?.discardRecording() } })
            }
        } else {
            NotificationPresenter.recordingStarted(title: meeting.displayTitle)
        }
        Log.info("Recording started for \(meeting.id)")
    }

    /// Stops capture and hands the meeting to the pipeline. With
    /// `startPipeline` false — used at quit — the meeting is left marked
    /// `.transcribing` and is picked up on the next launch.
    func stopRecording(startPipeline: Bool = true, offerNext: Bool = true) async {
        guard phase.isRecording, let engine, let meetingID = activeMeetingID else { return }
        defer { if offerNext, startPipeline { offerNextCall() } }

        stopElapsedTimer()
        let result = engine.stop()
        self.engine = nil
        // Every chunk is queued by now (stop flushes the mixer synchronously).
        // Let them all reach the transcriber before it is finished, so the
        // last words make it into the live text.
        chunkSink?.finish()
        chunkSink = nil
        if startPipeline { await chunkConsumer?.value }
        chunkConsumer = nil
        // Stopped by hand mid-call: don't offer the same call straight back.
        if let app = recordingApp, detector.isInCall(app.key) { detector.suppress(app.key) }
        self.recordingApp = nil
        self.recordingStartedAt = nil
        MeetingPromptPanel.shared.hide()
        NotificationPresenter.clearAutoRecordingNotice()

        // At quit there is no time to drain the speech analyzer; the text shown
        // so far is what there is.
        let finalLiveText = startPipeline
            ? (await transcriber?.finish() ?? activity.liveText)
            : activity.liveText
        self.transcriber = nil

        guard var meeting = store.fullMeeting(id: meetingID) else {
            phase = .idle
            activeMeetingID = nil
            return
        }

        // Too short to be a real meeting — keep the audio, skip the pipeline.
        let tooShort = result.duration < 5
        meeting.endedAt = Date()
        meeting.liveTranscript = finalLiveText
        if let reason = result.degradedReason {
            meeting.failureReason = reason
        }
        // Marked as transcribing straight away, not left as `.recording` while
        // it waits behind another meeting's pipeline: launch recovery treats
        // `.recording` as a crash mid-capture.
        meeting.state = tooShort ? .complete : .transcribing
        let energyFile = meeting.energyLogFile
        Self.energyWrites.sync { result.energy.write(to: energyFile) }
        store.save(meeting)

        Log.info("Recording stopped: \(String(format: "%.1f", result.duration))s of audio")

        if tooShort {
            phase = .idle
            activeMeetingID = nil
            warning = "That recording was under five seconds, so it wasn't transcribed."
            return
        }

        // The recorder is free the moment capture has stopped — phase must not
        // wait on the pipeline, or the next meeting cannot start.
        phase = .idle
        guard startPipeline else {
            activeMeetingID = nil
            return
        }

        // The pipeline runs in the background — stopping must free the recorder
        // immediately, not hold it for the length of a transcription. Pipelines
        // are chained so two Whisper runs never compete for the machine.
        enqueuePipeline(meetingID: meetingID, energy: result.energy)
    }

    /// Serialises meeting pipelines: a second meeting stopped while the first is
    /// still transcribing waits its turn rather than running Whisper twice at
    /// once, and recording stays available throughout.
    private var pipelineTask: Task<Void, Never>?

    private func enqueuePipeline(meetingID: UUID, energy: EnergyTrack?) {
        pipelineTask = Task { [previous = pipelineTask] in
            await previous?.value
            await self.process(meetingID: meetingID, energy: energy)
        }
    }

    /// Runs the transcription and summarization pipeline. Safe to call again on
    /// an existing meeting to redo it.
    ///
    /// Every save here goes through `store.update`, which re-reads the meeting:
    /// transcription takes minutes, and the user goes on editing notes and the
    /// title while it runs. Saving the copy read at the start rolled those edits
    /// back — and then summarized without them.
    func process(meetingID: UUID, energy: EnergyTrack? = nil) async {
        guard let meeting = store.fullMeeting(id: meetingID) else { return }
        guard processing[meetingID] == nil else { return }

        let energyTrack = energy ?? EnergyTrack.read(from: meeting.energyLogFile)

        // MARK: Transcribe
        store.update(id: meetingID) { $0.state = .transcribing }
        processing[meetingID] = .transcribing(progress: 0)
        defer { processing[meetingID] = nil }

        var refiner = WhisperRefiner()
        // Quantised to whole percents: phase is observed by every major view, so
        // publishing each raw stderr line would re-render the window per line
        // for the whole transcription.
        let lastPercent = Atomic(-1)
        refiner.onProgress = { [weak self] value in
            let percent = Int(value * 100)
            guard lastPercent.exchange(percent) != percent else { return }
            Task { @MainActor in
                guard let self, case .transcribing = self.processing[meetingID] else { return }
                self.processing[meetingID] = .transcribing(progress: value)
            }
        }

        do {
            let segments = try await refiner.transcribe(audioFile: meeting.mixedAudioFile,
                                                       energy: energyTrack)
            // Deleted while Whisper ran: nothing left to save into.
            guard store.update(id: meetingID, { $0.segments = segments }) != nil else { return }
        } catch is CancellationError {
            // The app is quitting. The meeting stays `.transcribing` and is
            // resumed on the next launch.
            return
        } catch {
            Log.error("Whisper failed: \(error.localizedDescription)")
            // Fall back to the live transcript rather than losing the meeting.
            if meeting.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let failed = store.update(id: meetingID, {
                    $0.state = .failed
                    $0.failureReason = error.localizedDescription
                }) else { return }
                warning = "\(failed.displayTitle): \(error.localizedDescription)"
                NotificationPresenter.failed(title: failed.displayTitle, reason: error.localizedDescription)
                return
            }
            warning = "Whisper couldn't run (\(error.localizedDescription)). Summarizing from the live transcript instead."
        }

        guard AppSettings.shared.autoSummarize,
              meeting.duration >= AppSettings.shared.minimumMeetingSeconds else {
            guard let done = store.update(id: meetingID, { $0.state = .complete }) else { return }
            NotificationPresenter.transcriptReady(title: done.displayTitle)
            return
        }

        // Clear our own pipeline entry first: summarize() refuses to run on a
        // meeting that is already processing, and from its point of view the
        // .transcribing entry this function still holds IS already processing.
        processing[meetingID] = nil
        await summarize(meetingID: meetingID)
    }

    /// Generates (or regenerates) the summary for a meeting.
    func summarize(meetingID: UUID) async {
        guard let meeting = store.fullMeeting(id: meetingID) else { return }
        guard processing[meetingID] == nil else { return }
        guard !meeting.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            warning = "There's no transcript to summarize."
            return
        }

        store.update(id: meetingID) { $0.state = .summarizing }
        processing[meetingID] = .summarizing
        defer { processing[meetingID] = nil }

        // Who was there, if the recording does not know yet: the calendar may
        // not have been readable — or synced — when it was made. Matched to
        // the event that was on when the meeting started, so the notes can
        // name the people in it.
        await attachCalendarEvent(meetingID: meetingID)

        do {
            // Summarizes the latest copy, so notes typed while Whisper ran are
            // included; `meeting` was read before the state change above.
            let latest = store.fullMeeting(id: meetingID) ?? meeting
            let result = try await ClaudeSummarizer()
                .summarize(meeting: latest, template: SummaryTemplate.named(latest.templateID))
            guard let done = store.update(id: meetingID, {
                $0.summaryMarkdown = result.notes
                // Named in the same run, and only over a placeholder that is
                // still there — not over a name typed while Claude was writing.
                if let title = result.title, MeetingTitle.needsGeneratedTitle($0) { $0.title = title }
                $0.summaryTemplateID = $0.templateID
                $0.summaryEditedAt = nil
                $0.state = .complete
                $0.failureReason = nil
            }) else { return }
            Log.info("Summary complete for \(meetingID)" + (result.title == nil ? "" : ", named from its notes"))
            NotificationPresenter.summaryReady(title: done.displayTitle)
        } catch is CancellationError {
            return
        } catch {
            Log.error("Summarization failed: \(error.localizedDescription)")
            guard let failed = store.update(id: meetingID, {
                $0.state = .failed
                $0.failureReason = error.localizedDescription
            }) else { return }
            warning = "\(failed.displayTitle): \(error.localizedDescription)"
            NotificationPresenter.failed(title: failed.displayTitle, reason: error.localizedDescription)
        }
    }

    /// Fills in a meeting's calendar event after the fact, when it has none.
    /// Never over a name the user chose: the title changes only if it is
    /// still a placeholder.
    private func attachCalendarEvent(meetingID: UUID) async {
        guard AppSettings.shared.calendarEnabled,
              let meeting = store.meeting(id: meetingID),
              meeting.calendarEventTitle == nil, meeting.attendees.isEmpty else { return }
        let startedAt = meeting.startedAt
        guard let event = await Task.detached(priority: .utility, operation: {
            CalendarService.shared.event(at: startedAt)
        }).value else { return }
        store.update(id: meetingID) { current in
            current.calendarEventTitle = event.title
            current.attendees = event.attendees
            current.attendeeEmails = event.attendeeEmails
            if MeetingTitle.isPlaceholder(current.title), !event.title.isEmpty { current.title = event.title }
        }
        Log.info("Matched \(meetingID) to its calendar event after recording (\(event.attendees.count) invited)")
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
        warning = nil
    }

    // MARK: - Helpers

    private func startElapsedTimer() {
        stopElapsedTimer()
        let start = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.activity.elapsed = elapsed
                self.stopIfSilent()
                self.checkpointEnergyIfDue()
            }
        }
        // A visible clock can drift a tick without anyone noticing; the
        // tolerance lets the system coalesce the wakeup.
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    /// Speaker labels come from the loudness track, which used to be written
    /// only at stop — a crash lost it, and the recovered audio could only be
    /// labelled "Speaker" throughout. A checkpoint every 30 s bounds the loss.
    private func checkpointEnergyIfDue() {
        guard Date().timeIntervalSince(lastEnergyCheckpoint) >= 30,
              let engine, let file = activeMeeting?.energyLogFile else { return }
        lastEnergyCheckpoint = Date()
        Self.energyWrites.async { engine.energySnapshot().write(to: file) }
    }

    /// Serialises checkpoints with the final write at stop, so a late
    /// checkpoint can never replace the complete track with a shorter one.
    private static let energyWrites = DispatchQueue(label: "com.minutesapp.Minutes.energy")
    private var lastEnergyCheckpoint = Date()

    /// Tries the meeting app's window title a few times: the call window is
    /// often still titled generically for the first seconds after joining.
    private func nameFromCallWindow(meetingID: UUID, detection: MeetingDetector.Detection,
                                    defaultTitle: String) {
        Task { [weak self] in
            for delay in [3, 12, 40] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.activeMeetingID == meetingID else { return }
                let found = await Task.detached(priority: .utility) {
                    CallWindowTitle.current(for: detection)
                }.value
                guard let found else { continue }
                var applied = false
                self.store.update(id: meetingID) { current in
                    // The calendar's name, or the user's, wins.
                    guard current.title == defaultTitle, current.calendarEventTitle == nil else { return }
                    current.title = found
                    applied = true
                }
                if applied { Log.info("Named the recording from the \(detection.appName) window") }
                return
            }
        }
    }

    private func stopIfSilent() {
        guard phase.isRecording, Date().timeIntervalSince(lastSoundAt) > Self.silenceLimit else { return }
        let title = activeMeeting?.displayTitle ?? "Meeting"
        Log.info("Auto-stopping recording after \(Int(Self.silenceLimit / 60)) minutes of silence")
        lastSoundAt = Date()   // one stop, not one per tick while it runs
        NotificationPresenter.autoStopped(title: title,
                                          reason: "no sound for \(Int(Self.silenceLimit / 60)) minutes.")
        Task { await stopRecording() }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// A recording costs about 115 MB an hour (16 kHz mono), and the Mac this
    /// most often runs out on is a 256 GB MacBook Air. Below half a gigabyte —
    /// a few hours — say so at the start, while there is still time to make
    /// room, rather than discovering it in a recording that stopped saving.
    nonisolated static func lowDiskWarning(available: Int64? = nil) -> String? {
        let bytes = available ?? ((try? AppPaths.meetingsRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage)
        guard let bytes, bytes < 500 * 1_000_000 else { return nil }
        let minutes = max(0, Int(Double(bytes) / 32_000 / 60))
        return "Your disk is nearly full — room for about \(minutes) minutes of recording. "
            + "Free up some space so this meeting is saved in full."
    }

    private static func defaultTitle(for detection: MeetingDetector.Detection?) -> String {
        let time = Formats.time(Date())
        if let detection {
            return "\(detection.displayName) call, \(time)"
        }
        return "Meeting at \(time)"
    }
}


/// Minimal lock-boxed integer for cross-thread deduplication.
private final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ value: Int) { self.value = value }
    func exchange(_ new: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let old = value; value = new; return old
    }
}
