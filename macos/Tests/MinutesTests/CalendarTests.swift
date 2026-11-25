import Foundation
import Testing
@testable import Minutes

struct CalendarTests {
    @Test func findsTheJoinLinkAmongOtherLinks() {
        let notes = """
        Agenda: https://contoso.sharepoint.com/agenda.docx
        ________________________________________________________________________________
        Microsoft Teams meeting
        Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=%7b%7d
        """
        #expect(CalendarService.meetingLink(inText: notes)?.host == "teams.microsoft.com")
        #expect(CalendarService.meetingLink(inText: "Room 4B, https://example.com/map") == nil)
        #expect(CalendarService.meetingLink(inText: "https://us02web.zoom.us/j/123456789")?.host == "us02web.zoom.us")
    }

    @Test func remindersRingOnceWithinTheLead() {
        let now = Date()
        func event(_ id: String, startsIn seconds: TimeInterval) -> CalendarService.Upcoming {
            .init(id: id, title: id, start: now.addingTimeInterval(seconds),
                  end: now.addingTimeInterval(seconds + 1800), meetingLink: nil)
        }
        let events = [event("soon", startsIn: 45), event("later", startsIn: 600),
                      event("just-started", startsIn: -30), event("long-running", startsIn: -900)]
        let due = MeetingReminders.due(events, now: now, alreadyReminded: [])
        #expect(due.map(\.id) == ["soon", "just-started"])
        #expect(MeetingReminders.due(events, now: now, alreadyReminded: ["soon"]).map(\.id) == ["just-started"])
    }

    @Test func briefPromptFillsEveryPlaceholder() {
        let event = CalendarService.Upcoming(id: "x", title: "Acme QBR", start: Date(), end: Date(),
                                             meetingLink: nil, attendees: ["Dana", "Sam"])
        #expect(event.briefPrompt.contains("\"Acme QBR\""))
        #expect(event.briefPrompt.contains(", with Dana, Sam."))
        #expect(!event.briefPrompt.contains("{{"))
        var solo = event
        solo.attendees = []
        #expect(!solo.briefPrompt.contains("with"))
    }
}
