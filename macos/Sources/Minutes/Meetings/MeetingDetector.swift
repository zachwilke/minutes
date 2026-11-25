import Foundation
import CoreAudio
import AppKit
import Combine

/// Watches for the start and end of real meetings.
///
/// The trick is that Core Audio exposes, per process, whether that process is
/// currently *running audio input*. Zoom sitting idle in the dock reports false;
/// Zoom in a call reports true. That is a far better signal than "is the app
/// running", and it costs one property read per process every few seconds.
@MainActor
final class MeetingDetector: ObservableObject {
    struct Detection: Equatable, Sendable {
        var bundleID: String
        var appName: String
        /// Browsers can use the microphone for all sorts of reasons, so we never
        /// auto-start on them without asking.
        var isAmbiguous: Bool
        /// For a browser: the meeting service its front tab is in ("Google
        /// Meet"), when the window title says so. Resolved when a call is
        /// confirmed, not per poll — the key stays the browser's, so switching
        /// tabs mid-call never splits or ends it.
        var service: String? = nil

        /// What to call it in a prompt or a title: "Google Meet", "Zoom".
        var displayName: String { service ?? appName }

        /// A dedicated call app, or a browser whose tab is a known meeting.
        var isRecognisedMeeting: Bool { !isAmbiguous || service != nil }

        /// Identity of the *app*, not the process. Helper processes come and go
        /// under different bundle IDs within one call — Teams' helper, Chrome's
        /// renderer — and treating each as a new meeting would split it.
        var key: String { appName }
    }

    /// The most relevant app holding the microphone right now, for display.
    @Published private(set) var current: Detection?

    /// Fired once per app when its call is confirmed — unless that app is
    /// suppressed.
    var onMeetingStarted: ((Detection) -> Void)?
    /// Fired when a confirmed app has released the microphone for long enough.
    var onMeetingEnded: ((Detection) -> Void)?

    private var timer: Timer?

    /// Each app is tracked on its own. With a single "current meeting", a Teams
    /// call joined before Zoom fully dropped was announced and thrown away, the
    /// Zoom recording ran on into it, and Teams ending never stopped it.
    private var activeStreak: [String: Int] = [:]
    private var inactiveStreak: [String: Int] = [:]
    private var announced: [String: Detection] = [:]
    /// Apps the user ignored or stopped recording, until their call ends.
    private var suppressed: Set<String> = []

    /// Two polls (~6 s) of agreement before we act, so a notification chime or a
    /// quick "can you hear me" test doesn't trigger a recording.
    private let startConfirmations = 2
    /// Five polls (~15 s) without the microphone before a call counts as over.
    /// Switching headsets or toggling audio settings releases the microphone
    /// briefly, and ending the meeting there would split it in two.
    private let endConfirmations = 5
    private let pollInterval: TimeInterval = 3

    // Matched by case-insensitive prefix. Prefix, because helper processes report
    // IDs like "com.google.Chrome.helper" while holding the microphone;
    // case-insensitive, because Teams has shipped as both "com.microsoft.teams"
    // and "com.microsoft.Teams" and a case-sensitive miss would be silent.
    // Generated from shared/prompts/detection-apps.json, so both platforms
    // recognise the same conferencing apps.
    nonisolated private static let conferencingApps: [(prefix: String, name: String, ambiguous: Bool)] =
        SharedPrompts.Detection.apps.map { ($0.prefix, $0.name, $0.ambiguous) }

    func start() {
        stop()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Half a second of slack on a three-second poll lets the system batch
        // the wakeup with others; detection still confirms over two polls, so
        // the added latency is noise.
        timer.tolerance = 0.5
        // .common keeps it firing while menus are open, which is exactly when a
        // meeting is likely to start.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
        Log.info("Meeting detection started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeStreak.removeAll()
        inactiveStreak.removeAll()
        announced.removeAll()
        suppressed.removeAll()
        current = nil
    }

    /// Stops this app's current call from being offered (again). Lifted when the
    /// call ends, so the next call in the same app is detected normally.
    func suppress(_ key: String) {
        suppressed.insert(key)
    }

    /// Whether this app's call is confirmed and has not ended.
    func isInCall(_ key: String) -> Bool {
        announced[key] != nil
    }

    /// Confirmed calls currently holding the microphone, dedicated apps first.
    var callsInProgress: [Detection] {
        announced.values
            .filter { inactiveStreak[$0.key, default: 0] == 0 }
            .sorted { !$0.isAmbiguous && $1.isAmbiguous }
    }

    /// Calls in progress that the user has not ignored — what to offer next once
    /// the recorder frees up.
    var unhandledCalls: [Detection] {
        callsInProgress.filter { !suppressed.contains($0.key) }
    }

    private func poll() {
        ingest(Self.activeConferencingApps())
    }

    /// One poll's worth of state change, given what Core Audio reported.
    /// Separate from `poll` so the rules can be exercised without real calls.
    func ingest(_ found: [Detection]) {
        let foundKeys = Set(found.map(\.key))
        current = found.first

        for detection in found {
            inactiveStreak[detection.key] = 0
            activeStreak[detection.key, default: 0] += 1
            guard announced[detection.key] == nil,
                  activeStreak[detection.key, default: 0] >= startConfirmations else { continue }
            announced[detection.key] = detection
            Log.info("Meeting detected: \(detection.appName)")
            if !suppressed.contains(detection.key) {
                onMeetingStarted?(detection)
            }
        }

        // An unconfirmed blip starts its count again next time.
        for key in activeStreak.keys where !foundKeys.contains(key) {
            activeStreak[key] = nil
        }

        for (key, detection) in announced where !foundKeys.contains(key) {
            inactiveStreak[key, default: 0] += 1
            guard inactiveStreak[key, default: 0] >= endConfirmations else { continue }
            announced[key] = nil
            inactiveStreak[key] = nil
            suppressed.remove(key)
            Log.info("Meeting ended: \(detection.appName)")
            onMeetingEnded?(detection)
        }
    }

    /// The conferencing-app table, for audit and cross-platform comparison.
    /// Canonical copy lives in shared/prompts/detection-apps.json.
    nonisolated static func auditApps() -> [(prefix: String, name: String, ambiguous: Bool)] {
        conferencingApps
    }

    // MARK: - Diagnostics

    /// One row per process Core Audio knows about, for `--test-detection`.
    struct ProcessReport: Sendable {
        var bundleID: String
        var isRunningInput: Bool
        var isRunningOutput: Bool
        var matchedApp: String?
        var isAmbiguous: Bool
    }

    /// A snapshot of what the detector can currently see. This is the answer to
    /// "why didn't it notice my meeting?" — either the app is not holding the
    /// microphone, or its bundle identifier is not in the known list.
    nonisolated static func snapshot() -> [ProcessReport] {
        processObjectList().compactMap { object in
            guard let bundleID = bundleID(of: object) else { return nil }
            let match = conferencingApps.first {
                bundleID.lowercased().hasPrefix($0.prefix.lowercased())
            }
            return ProcessReport(bundleID: bundleID,
                                 isRunningInput: isRunningInput(object),
                                 isRunningOutput: isRunningOutput(object),
                                 matchedApp: match?.name,
                                 isAmbiguous: match?.ambiguous ?? false)
        }
    }

    /// What the detector would conclude right now.
    nonisolated static func currentDetection() -> Detection? {
        activeConferencingApps().first
    }

    // MARK: - Core Audio process inspection

    /// Every known conferencing app currently capturing audio, one entry per
    /// app, dedicated apps before ambiguous browsers.
    nonisolated private static func activeConferencingApps() -> [Detection] {
        var matches: [Detection] = []
        for processObject in processObjectList() {
            guard isRunningInput(processObject),
                  let bundleID = bundleID(of: processObject),
                  let app = conferencingApps.first(where: {
                      bundleID.lowercased().hasPrefix($0.prefix.lowercased())
                  }),
                  !matches.contains(where: { $0.appName == app.name })
            else { continue }
            matches.append(Detection(bundleID: bundleID, appName: app.name, isAmbiguous: app.ambiguous))
        }
        return matches.filter { !$0.isAmbiguous } + matches.filter(\.isAmbiguous)
    }

    nonisolated private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                            &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects
    }

    nonisolated private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    nonisolated private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    nonisolated private static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
