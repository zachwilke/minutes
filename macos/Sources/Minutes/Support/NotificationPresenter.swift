import Foundation
import UserNotifications
import AppKit

/// Banner notifications, and the routing for the buttons on them.
///
/// The meeting-detected banner carries Record and Ignore actions, so joining a
/// call can be captured without opening the app at all. Handling those taps
/// requires a delegate, and the delegate has to be installed before any
/// notification is delivered — see `NotificationRouter`.
enum NotificationPresenter {
    /// Category carrying the Record / Ignore buttons.
    static let meetingCategory = "MEETING_DETECTED"
    static let recordAction = "MEETING_RECORD"
    static let ignoreAction = "MEETING_IGNORE"
    /// Category for a recording that started by itself: Stop and Discard.
    static let autoRecordingCategory = "RECORDING_AUTO"
    static let stopAction = "RECORDING_STOP"
    static let discardAction = "RECORDING_DISCARD"
    /// Category for the one-minute calendar reminder.
    static let reminderCategory = "MEETING_SOON"
    static let joinAction = "MEETING_JOIN"

    private static var isAuthorized = false

    /// Registers the actionable category and asks for permission.
    /// Categories must be registered before a notification referencing them is
    /// posted, otherwise the buttons silently do not appear.
    @MainActor
    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationRouter.shared

        let record = UNNotificationAction(identifier: recordAction,
                                         title: "Record",
                                         options: [.foreground])
        let ignore = UNNotificationAction(identifier: ignoreAction,
                                         title: "Ignore",
                                         options: [])
        let category = UNNotificationCategory(identifier: meetingCategory,
                                              actions: [record, ignore],
                                              intentIdentifiers: [],
                                              options: [])
        let stop = UNNotificationAction(identifier: stopAction, title: "Stop", options: [])
        let discard = UNNotificationAction(identifier: discardAction, title: "Discard",
                                           options: [.destructive])
        let autoCategory = UNNotificationCategory(identifier: autoRecordingCategory,
                                                  actions: [stop, discard],
                                                  intentIdentifiers: [],
                                                  options: [])
        let join = UNNotificationAction(identifier: joinAction, title: "Join & Record",
                                        options: [.foreground])
        let reminderCategory = UNNotificationCategory(identifier: reminderCategory,
                                                      actions: [join],
                                                      intentIdentifiers: [],
                                                      options: [])
        center.setNotificationCategories([category, autoCategory, reminderCategory])

        // The system prompt is only raised here for users who have already been
        // through onboarding (where it is asked with context). On a first launch
        // it would otherwise appear the moment the app starts, before the window
        // has said a word about why.
        if AppSettings.shared.hasCompletedOnboarding {
            request(completion: nil)
        } else {
            refreshAuthorization()
        }
    }

    /// Raises the system prompt (a no-op prompt-wise once the status is
    /// settled). Used by onboarding, and at launch for returning users.
    static func request(completion: (@Sendable (Bool) -> Void)?) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                isAuthorized = granted
                if let error {
                    let nsError = error as NSError
                    Log.warn("Notification authorization failed: \(error.localizedDescription) "
                             + "[domain=\(nsError.domain) code=\(nsError.code)]")
                }
                refreshAuthorization(completion: completion)
            }
    }

    /// Re-reads the system's view of our authorization, which the user can change
    /// in System Settings at any time.
    static func refreshAuthorization(completion: (@Sendable (Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            isAuthorized = allowed
            Log.info("Notification settings: authorization=\(settings.authorizationStatus.rawValue) allowed=\(allowed)")
            completion?(allowed)
        }
    }

    /// Whether a banner will actually be delivered. The caller uses this to
    /// decide whether to fall back to the in-app floating prompt.
    static var canDeliver: Bool { isAuthorized }

    // MARK: - Posting

    /// The prompt shown when a conferencing app starts using the microphone.
    static func meetingDetected(appName: String, ambiguous: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "\(appName) call detected"
        content.body = ambiguous
            ? "\(appName) is using your microphone. Record this as a meeting?"
            : "Start recording and take notes?"
        content.categoryIdentifier = meetingCategory
        content.sound = .default
        // A stable identifier means a second detection replaces the first rather
        // than stacking banners.
        post(content, identifier: "meeting-detected")
    }

    /// Announces a recording nobody clicked Record for. It always says so,
    /// with a way out: recording without the user's say-so is only acceptable
    /// when it is impossible to miss and one click to undo.
    static func autoRecordingStarted(appName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Recording your \(appName) call"
        content.body = "Notes will be written when it ends. Stop, or Discard to delete the recording."
        content.categoryIdentifier = autoRecordingCategory
        content.sound = .default
        post(content, identifier: "recording-auto")
    }

    /// A minute before a calendar meeting. Join & Record opens its link, if it
    /// has one, and starts recording.
    static func meetingStartingSoon(_ event: CalendarService.Upcoming) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        let time = Formats.time(event.start)
        content.body = event.meetingLink == nil
            ? "Starts at \(time). Record it?"
            : "Starts at \(time). Join the call and record it?"
        content.categoryIdentifier = reminderCategory
        content.sound = .default
        content.userInfo = ["title": event.title, "link": event.meetingLink?.absoluteString ?? ""]
        post(content, identifier: "reminder-\(event.id)")
    }

    static func clearAutoRecordingNotice() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["recording-auto"])
    }

    static func autoStopped(title: String, reason: String) {
        post(simple(title: "Recording stopped", body: "\(title) — \(reason)"),
             identifier: UUID().uuidString)
    }

    static func recordingStarted(title: String) {
        post(simple(title: "Recording", body: title), identifier: UUID().uuidString)
    }

    static func transcriptReady(title: String) {
        post(simple(title: "Transcript ready", body: title), identifier: UUID().uuidString)
    }

    static func summaryReady(title: String) {
        post(simple(title: "Notes ready", body: title), identifier: UUID().uuidString)
    }

    static func failed(title: String, reason: String) {
        post(simple(title: "Minutes had a problem", body: "\(title): \(reason)"),
             identifier: UUID().uuidString)
    }

    /// Withdraws the detection banner once it is no longer relevant.
    static func clearMeetingPrompt() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: ["meeting-detected"])
    }

    private static func simple(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return content
    }

    private static func post(_ content: UNNotificationContent, identifier: String) {
        guard isAuthorized else { return }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.warn("Notification failed: \(error.localizedDescription)") }
        }
    }

    /// Opens System Settings at the Notifications pane.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Receives notification taps and forwards them into the app.
///
/// UNUserNotificationCenter needs an NSObject delegate, and it must be set
/// during launch rather than lazily — a tap on a banner delivered before the
/// delegate exists is dropped.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = NotificationRouter()

    /// Set by the app once the coordinator exists.
    @MainActor var onRecordRequested: (() -> Void)?
    @MainActor var onIgnoreRequested: (() -> Void)?
    @MainActor var onStopRequested: (() -> Void)?
    @MainActor var onDiscardRequested: (() -> Void)?
    /// Join & Record on a reminder: the event's title and join link, if any.
    @MainActor var onJoinRequested: ((String, URL?) -> Void)?
    @MainActor var onOpenRequested: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let title = info["title"] as? String ?? "Meeting"
        let link = (info["link"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        Task { @MainActor in
            switch action {
            case NotificationPresenter.recordAction:
                onRecordRequested?()
            case NotificationPresenter.ignoreAction:
                onIgnoreRequested?()
            case NotificationPresenter.stopAction:
                onStopRequested?()
            case NotificationPresenter.discardAction:
                onDiscardRequested?()
            case NotificationPresenter.joinAction:
                onJoinRequested?(title, link)
            case UNNotificationDefaultActionIdentifier:
                // Tapping the banner body itself: bring the app forward rather
                // than starting a recording the user did not explicitly ask for.
                onOpenRequested?()
            default:
                break
            }
            completionHandler()
        }
    }

    /// Show banners even while Minutes is the frontmost app, otherwise the
    /// prompt is invisible exactly when someone is looking at their notes.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
