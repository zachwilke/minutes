import Testing
@testable import Minutes

/// The detector's rules, driven with simulated Core Audio polls (one `ingest`
/// is one 3-second poll).
@MainActor
struct MeetingDetectorTests {
    let zoom = MeetingDetector.Detection(bundleID: "us.zoom.xos", appName: "Zoom", isAmbiguous: false)
    let teams = MeetingDetector.Detection(bundleID: "com.microsoft.teams2.helper",
                                          appName: "Microsoft Teams", isAmbiguous: false)
    let teamsMain = MeetingDetector.Detection(bundleID: "com.microsoft.teams2",
                                              appName: "Microsoft Teams", isAmbiguous: false)

    final class Recorder {
        var events: [String] = []
        func take() -> [String] { defer { events.removeAll() }; return events }
    }

    func makeDetector() -> (MeetingDetector, Recorder) {
        let detector = MeetingDetector()
        let recorder = Recorder()
        detector.onMeetingStarted = { recorder.events.append("start \($0.appName)") }
        detector.onMeetingEnded = { recorder.events.append("end \($0.appName)") }
        return (detector, recorder)
    }

    func polls(_ detector: MeetingDetector, _ count: Int, _ found: [MeetingDetector.Detection]) {
        for _ in 0..<count { detector.ingest(found) }
    }

    @Test func startNeedsTwoConsecutivePolls() {
        let (d, r) = makeDetector()
        polls(d, 1, [zoom]); polls(d, 1, []); polls(d, 1, [zoom])
        #expect(r.take().isEmpty)
        polls(d, 1, [zoom])
        #expect(r.take() == ["start Zoom"])
    }

    @Test func briefMicrophoneReleaseDoesNotEndTheCall() {
        let (d, r) = makeDetector()
        polls(d, 2, [zoom]); _ = r.take()
        polls(d, 4, []); polls(d, 1, [zoom])
        #expect(r.take().isEmpty)
        polls(d, 5, [])
        #expect(r.take() == ["end Zoom"])
    }

    @Test func backToBackCallsAreTrackedSeparately() {
        let (d, r) = makeDetector()
        polls(d, 2, [zoom])
        polls(d, 2, [zoom, teams])
        #expect(r.take() == ["start Zoom", "start Microsoft Teams"])
        polls(d, 5, [teams])
        #expect(r.take() == ["end Zoom"])
        #expect(d.callsInProgress.map(\.appName) == ["Microsoft Teams"])
    }

    @Test func helperProcessSwapIsTheSameCall() {
        let (d, r) = makeDetector()
        polls(d, 2, [teams]); _ = r.take()
        polls(d, 3, [teamsMain])
        #expect(r.take().isEmpty)
    }

    @Test func suppressionLastsUntilTheCallEnds() {
        let (d, r) = makeDetector()
        polls(d, 2, [zoom]); _ = r.take()
        d.suppress("Zoom")
        #expect(d.isInCall("Zoom"))
        #expect(d.unhandledCalls.isEmpty)
        polls(d, 5, [])
        #expect(r.take() == ["end Zoom"])
        polls(d, 2, [zoom])
        #expect(r.take() == ["start Zoom"])
    }
}
