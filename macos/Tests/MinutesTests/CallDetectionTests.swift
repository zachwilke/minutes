import Testing
@testable import Minutes

/// What happens when a call starts: which ones record by themselves, which
/// are offered, and what a browser tab says about the call it holds.
struct CallDetectionTests {
    private let teams = MeetingDetector.Detection(bundleID: "com.microsoft.teams2.helper",
                                                  appName: "Microsoft Teams", isAmbiguous: false)
    private let chrome = MeetingDetector.Detection(bundleID: "com.google.Chrome.helper",
                                                   appName: "Chrome", isAmbiguous: true)
    private var meetInChrome: MeetingDetector.Detection {
        var detection = chrome
        detection.service = "Google Meet"
        return detection
    }

    // MARK: - Record or offer

    @Test func unscheduledCallsAreOffered() {
        #expect(!RecordingCoordinator.recordsAutomatically(teams, mode: .autoRecord, eventHasLink: nil))
        #expect(!RecordingCoordinator.recordsAutomatically(meetInChrome, mode: .autoRecord, eventHasLink: nil))
        #expect(!RecordingCoordinator.recordsAutomatically(chrome, mode: .autoRecord, eventHasLink: nil))
    }

    @Test func scheduledCallsRecordThemselves() {
        // Dedicated apps and recognised meeting tabs: any meeting on the calendar.
        #expect(RecordingCoordinator.recordsAutomatically(teams, mode: .autoRecord, eventHasLink: false))
        #expect(RecordingCoordinator.recordsAutomatically(meetInChrome, mode: .autoRecord, eventHasLink: false))
    }

    /// A browser that could be anything needs the event's own join link.
    @Test func anUnrecognisedBrowserNeedsTheJoinLink() {
        #expect(!RecordingCoordinator.recordsAutomatically(chrome, mode: .autoRecord, eventHasLink: false))
        #expect(RecordingCoordinator.recordsAutomatically(chrome, mode: .autoRecord, eventHasLink: true))
    }

    @Test func alwaysAskNeverRecordsByItself() {
        #expect(!RecordingCoordinator.recordsAutomatically(teams, mode: .ask, eventHasLink: true))
    }

    // MARK: - False starts

    @Test func aShortAutomaticRecordingWithNothingTypedIsAFalseStart() {
        #expect(RecordingCoordinator.isFalseStart(automatic: true, duration: 24, notes: ""))
        #expect(RecordingCoordinator.isFalseStart(automatic: true, duration: 4, notes: "  \n"))
    }

    @Test func anythingElseIsKept() {
        #expect(!RecordingCoordinator.isFalseStart(automatic: false, duration: 4, notes: ""))      // clicked
        #expect(!RecordingCoordinator.isFalseStart(automatic: true, duration: 60, notes: ""))      // long enough
        #expect(!RecordingCoordinator.isFalseStart(automatic: true, duration: 10, notes: "budget")) // typed into
    }

    // MARK: - Browser tabs

    @Test func meetTabsAreGoogleMeet() {
        #expect(BrowserMeeting.identify("Meet - abc-defg-hij") == .init(service: "Google Meet", name: nil))
        #expect(BrowserMeeting.identify("Meet – Weekly sync") == .init(service: "Google Meet", name: "Weekly sync"))
        #expect(BrowserMeeting.identify("(2) Meet - Weekly sync - Google Chrome") == .init(service: "Google Meet", name: "Weekly sync"))
        #expect(BrowserMeeting.identify("Meet - abc-defg-hij - Camera or microphone recording")
                == .init(service: "Google Meet", name: nil))
    }

    @Test func teamsAndZoomOnTheWeb() {
        #expect(BrowserMeeting.identify("Northwind Status Call | Microsoft Teams")
                == .init(service: "Microsoft Teams", name: "Northwind Status Call"))
        #expect(BrowserMeeting.identify("Zoom Meeting") == .init(service: "Zoom", name: nil))
    }

    @Test func ordinaryPagesAreNotMeetings() {
        #expect(BrowserMeeting.identify("Inbox (3) - zach@example.com - Gmail") == nil)
        #expect(BrowserMeeting.identify("Voice Memos — Online Recorder") == nil)
        #expect(BrowserMeeting.identify(["Inbox - Gmail", "Meet – Weekly sync"])?.service == "Google Meet")
    }

    @Test func aRecognisedTabIsNamedForItsService() {
        #expect(meetInChrome.displayName == "Google Meet")
        #expect(meetInChrome.isRecognisedMeeting)
        #expect(!chrome.isRecognisedMeeting)
        #expect(chrome.displayName == "Chrome")
        // The detector's identity stays the browser's, so switching tabs
        // mid-call never splits the call.
        #expect(meetInChrome.key == chrome.key)
    }
}
