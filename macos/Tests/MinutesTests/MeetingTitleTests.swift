import Testing
@testable import Minutes

/// Window titles here are real ones, from a library recorded with new Teams.
struct MeetingTitleTests {

    // MARK: - Cleaning call-window titles

    @Test func newTeamsTrailersAreRemoved() {
        #expect(MeetingTitle.fromWindow("Northwind Status Call | Example Corp | you@example.com")
                == "Northwind Status Call")
        #expect(MeetingTitle.fromWindow("Vantage Demo | Example Corp | you@example.com") == "Vantage Demo")
        #expect(MeetingTitle.fromWindow("Marcus Vale | Example Corp | you@example.com") == "Marcus Vale")
    }

    @Test func classicTeamsSuffixIsRemoved() {
        #expect(MeetingTitle.fromWindow("Acme quarterly review | Microsoft Teams") == "Acme quarterly review")
        #expect(MeetingTitle.fromWindow("Acme quarterly review - Microsoft Teams") == "Acme quarterly review")
    }

    @Test func theJoinLobbyNamesNothing() {
        #expect(MeetingTitle.fromWindow("Meeting join | Microsoft Teams meeting | Example Corp | you@example.com") == nil)
        #expect(MeetingTitle.fromWindow("Microsoft Teams") == nil)
    }

    @Test func adHocCallsReadAsCalls() {
        #expect(MeetingTitle.fromWindow("Teams call with Priya Raman | Example Corp | you@example.com")
                == "Call with Priya Raman")
    }

    /// A name the user typed with a bar in it is left alone: nothing in it is
    /// an email address or the app's name.
    @Test func ordinaryBarsSurvive() {
        #expect(MeetingTitle.fromWindow("Q3 | Budget review") == "Q3 | Budget review")
    }

    @Test func newTeamsMainWindowIsStillSkipped() {
        let titles = ["Chat | Dana Whitfield | Example Corp | you@example.com",
                      "Northwind Status Call | Example Corp | you@example.com"]
        #expect(CallWindowTitle.bestTitle(from: titles, appName: "Microsoft Teams") == "Northwind Status Call")
        #expect(CallWindowTitle.bestTitle(from: ["Chat | Dana Whitfield | Example Corp | you@example.com"],
                                          appName: "Microsoft Teams") == nil)
    }

    // MARK: - Placeholders

    @Test func startupNamesArePlaceholders() {
        for title in ["Meeting at 13:05", "Meeting at 9:32\u{202F}AM", "Meeting at 9:32 pm", "Meeting at 21.32",
                      "Microsoft Teams call, 13:51", "Zoom call, 10:02\u{202F}AM", "Call with Priya Raman", "", "Meeting"] {
            #expect(MeetingTitle.isPlaceholder(title), "\(title)")
        }
    }

    @Test func realNamesAreNot() {
        for title in ["Northwind Status Call", "Vantage AI Transition Phase 2", "Lakeside Onedrive Sync Issies",
                      "Marcus Vale", "Meeting at the Acme office", "Weekly call, notes"] {
            #expect(!MeetingTitle.isPlaceholder(title), "\(title)")
        }
    }

    @Test func calendarNamedMeetingsAreNeverRenamed() {
        var meeting = Meeting(title: "Meeting at 9:32 AM", startedAt: .now)
        #expect(MeetingTitle.needsGeneratedTitle(meeting))
        meeting.calendarEventTitle = "Weekly sync"
        #expect(!MeetingTitle.needsGeneratedTitle(meeting))
    }

    // MARK: - Model replies

    @Test func repliesAreTrimmedToATitle() {
        #expect(MeetingTitle.sanitize("\"Acme: firewall renewal.\"") == "Acme: firewall renewal")
        #expect(MeetingTitle.sanitize("Title: Northwind file server cutover\n\nThis meeting covered…")
                == "Northwind file server cutover")
        #expect(MeetingTitle.sanitize("# **Vantage AI rollout**") == "Vantage AI rollout")
        #expect(MeetingTitle.sanitize("  \n ") == nil)
        #expect(MeetingTitle.sanitize("ok") == nil)
        // A real reply from a run where the model could not name the client.
        #expect(MeetingTitle.sanitize("Acme-style client title: the client is an East Texas oilfield disposal and saltwater company") == nil)
    }

}
