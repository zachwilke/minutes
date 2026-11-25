import Foundation
import Combine

/// What happens when a conferencing app starts a call.
enum DetectionMode: String, CaseIterable, Identifiable, Sendable {
    /// A call during a meeting on the calendar records at once, with Stop and
    /// Discard on the banner; any other call is offered. An unrecognised
    /// browser also needs the event's join link to record by itself.
    case autoRecord
    /// Every detected call asks first.
    case ask

    var id: String { rawValue }
}

/// User preferences, backed by UserDefaults so they are readable from any thread
/// (the Whisper and Claude stages run off the main actor).
final class AppSettings: ObservableObject, @unchecked Sendable {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Keys.autoDetectMeetings: true,
            Keys.detectionMode: DetectionMode.autoRecord.rawValue,
            Keys.autoSummarize: true,
            Keys.claudeModel: "sonnet",
            Keys.defaultTemplateID: SummaryTemplate.general.id,
            Keys.minimumMeetingSeconds: 45.0,
            Keys.captureSystemAudio: true,
            Keys.captureMicrophone: true,
            Keys.calendarEnabled: false,
            Keys.meetingReminders: true,
            Keys.menuBarText: true,
            Keys.echoCancellation: true,
            Keys.nameFromCallWindow: true,
            Keys.audioRetentionDays: 0,
            Keys.transcriptionLanguage: "auto",
            Keys.notesLanguage: "",
            Keys.translucentWindow: true,
            Keys.showInDock: true,
            Keys.hasCompletedOnboarding: false
        ])
    }

    private enum Keys {
        static let whisperModelPath = "whisperModelPath"
        static let autoDetectMeetings = "autoDetectMeetings"
        static let detectionMode = "detectionMode"
        static let autoSummarize = "autoSummarize"
        static let claudeModel = "claudeModel"
        static let defaultTemplateID = "defaultTemplateID"
        static let minimumMeetingSeconds = "minimumMeetingSeconds"
        static let captureSystemAudio = "captureSystemAudio"
        static let captureMicrophone = "captureMicrophone"
        static let calendarEnabled = "calendarEnabled"
        static let meetingReminders = "meetingReminders"
        static let menuBarText = "menuBarText"
        static let echoCancellation = "echoCancellation"
        static let nameFromCallWindow = "nameFromCallWindow"
        static let permissionsAsked = "permissionsAsked"
        static let excludedCalendarIDs = "excludedCalendarIDs"
        static let audioRetentionDays = "audioRetentionDays"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let notesLanguage = "notesLanguage"
        static let seriesTemplates = "seriesTemplates"
        static let translucentWindow = "translucentWindow"
        static let showInDock = "showInDock"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let titlesBackfilled = "titlesBackfilled"
    }

    /// Publishes on the main actor so SwiftUI stays happy regardless of caller.
    private func announce() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        }
    }

    /// Explicit model override; when nil we auto-pick the best model on disk.
    var whisperModelPath: String? {
        get { defaults.string(forKey: Keys.whisperModelPath) }
        set { announce(); defaults.set(newValue, forKey: Keys.whisperModelPath) }
    }

    var autoDetectMeetings: Bool {
        get { defaults.bool(forKey: Keys.autoDetectMeetings) }
        set { announce(); defaults.set(newValue, forKey: Keys.autoDetectMeetings) }
    }

    var detectionMode: DetectionMode {
        get { DetectionMode(rawValue: defaults.string(forKey: Keys.detectionMode) ?? "") ?? .autoRecord }
        set { announce(); defaults.set(newValue.rawValue, forKey: Keys.detectionMode) }
    }

    var autoSummarize: Bool {
        get { defaults.bool(forKey: Keys.autoSummarize) }
        set { announce(); defaults.set(newValue, forKey: Keys.autoSummarize) }
    }

    /// Passed to `claude --model`. Your Claude subscription covers the usage.
    var claudeModel: String {
        get { defaults.string(forKey: Keys.claudeModel) ?? "sonnet" }
        set { announce(); defaults.set(newValue, forKey: Keys.claudeModel) }
    }

    var defaultTemplateID: String {
        get { defaults.string(forKey: Keys.defaultTemplateID) ?? SummaryTemplate.general.id }
        set { announce(); defaults.set(newValue, forKey: Keys.defaultTemplateID) }
    }

    /// Recordings shorter than this are kept but never auto-summarized, so a
    /// mis-fire on a 10-second notification sound doesn't spawn a summary.
    var minimumMeetingSeconds: Double {
        get { defaults.double(forKey: Keys.minimumMeetingSeconds) }
        set { announce(); defaults.set(newValue, forKey: Keys.minimumMeetingSeconds) }
    }

    var captureSystemAudio: Bool {
        get { defaults.bool(forKey: Keys.captureSystemAudio) }
        set { announce(); defaults.set(newValue, forKey: Keys.captureSystemAudio) }
    }

    var captureMicrophone: Bool {
        get { defaults.bool(forKey: Keys.captureMicrophone) }
        set { announce(); defaults.set(newValue, forKey: Keys.captureMicrophone) }
    }


    /// Set once the first-launch walkthrough has been finished or skipped.
    /// Set once the library's placeholder titles have been named. The pass
    /// runs once, after an update that introduced titling; new meetings are
    /// named as their notes are written.
    var titlesBackfilled: Bool {
        get { defaults.bool(forKey: Keys.titlesBackfilled) }
        set { defaults.set(newValue, forKey: Keys.titlesBackfilled) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { announce(); defaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    /// Whether the app keeps a Dock icon. Off means it lives only in the menu
    /// bar; the status item is then the only way in, which is why it can never be
    /// hidden.
    var showInDock: Bool {
        get { defaults.bool(forKey: Keys.showInDock) }
        set { announce(); defaults.set(newValue, forKey: Keys.showInDock) }
    }

    /// Blurred, slightly transparent window chrome. Some people find vibrancy
    /// harder to read against a busy desktop, so it can be switched off for a
    /// solid background.
    var translucentWindow: Bool {
        get { defaults.bool(forKey: Keys.translucentWindow) }
        set { announce(); defaults.set(newValue, forKey: Keys.translucentWindow) }
    }

    /// Whisper's `-l` code: "auto" detects per recording; a fixed language is
    /// more accurate when every meeting is in it.
    var transcriptionLanguage: String {
        get { defaults.string(forKey: Keys.transcriptionLanguage) ?? "auto" }
        set { announce(); defaults.set(newValue, forKey: Keys.transcriptionLanguage) }
    }

    /// The language notes are written in, by English name. Empty follows the
    /// meeting's own language.
    var notesLanguage: String {
        get { defaults.string(forKey: Keys.notesLanguage) ?? "" }
        set { announce(); defaults.set(newValue, forKey: Keys.notesLanguage) }
    }

    /// The summary style last chosen for each recurring calendar meeting, keyed
    /// by event title — so the weekly 1:1 is written as a 1:1 without picking it
    /// every week.
    func template(forSeries title: String) -> String? {
        (defaults.dictionary(forKey: Keys.seriesTemplates) as? [String: String])?[title]
    }

    func setTemplate(_ id: String, forSeries title: String) {
        var all = (defaults.dictionary(forKey: Keys.seriesTemplates) as? [String: String]) ?? [:]
        all[title] = id
        defaults.set(all, forKey: Keys.seriesTemplates)
    }

    /// Recordings older than this lose their audio; transcript, notes and summary
    /// stay. 0 keeps audio forever.
    var audioRetentionDays: Int {
        get { defaults.integer(forKey: Keys.audioRetentionDays) }
        set { announce(); defaults.set(newValue, forKey: Keys.audioRetentionDays) }
    }

    /// Cancel the call's audio out of the microphone, so speakers do not leak
    /// the far side into "You". Takes effect from the next recording.
    var echoCancellation: Bool {
        get { defaults.bool(forKey: Keys.echoCancellation) }
        set { announce(); defaults.set(newValue, forKey: Keys.echoCancellation) }
    }

    /// Name recordings from the meeting app's window title (Teams, Webex) when
    /// the calendar has no event. Needs Accessibility permission.
    var nameFromCallWindow: Bool {
        get { defaults.bool(forKey: Keys.nameFromCallWindow) }
        set { announce(); defaults.set(newValue, forKey: Keys.nameFromCallWindow) }
    }

    /// Permissions the user has already been walked through, by onboarding
    /// step name. A permission added in a later version is asked about once,
    /// at the next launch — never again after that.
    /// Who "You" is in every transcript: the person whose Mac this is. Sent
    /// to Claude so notes say "Alex agreed to…" rather than "the person on the
    /// microphone". Defaults to the Mac account's full name.
    var myName: String {
        get {
            let stored = defaults.string(forKey: "myName")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? NSFullUserName() : stored
        }
        set { announce(); defaults.set(newValue, forKey: "myName") }
    }

    /// Calendars switched off in Settings. Stored as exclusions so a calendar
    /// added later — the Outlook account synced in next week — counts at once.
    var excludedCalendarIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.excludedCalendarIDs) ?? []) }
        set { announce(); defaults.set(Array(newValue).sorted(), forKey: Keys.excludedCalendarIDs) }
    }

    var permissionsAsked: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.permissionsAsked) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Keys.permissionsAsked) }
    }

    /// Text beside the menu bar icon: the recording clock, or the next meeting
    /// when one is about to start. Off leaves the icon alone.
    var menuBarText: Bool {
        get { defaults.bool(forKey: Keys.menuBarText) }
        set { announce(); defaults.set(newValue, forKey: Keys.menuBarText) }
    }

    /// A notification a minute before each calendar meeting, with Join & Record.
    /// Only meaningful with the calendar enabled.
    var meetingReminders: Bool {
        get { defaults.bool(forKey: Keys.meetingReminders) }
        set { announce(); defaults.set(newValue, forKey: Keys.meetingReminders) }
    }

    /// Off by default: turning it on is what triggers the Calendar permission
    /// prompt, and the app works fine without it.
    var calendarEnabled: Bool {
        get { defaults.bool(forKey: Keys.calendarEnabled) }
        set { announce(); defaults.set(newValue, forKey: Keys.calendarEnabled) }
    }
}
