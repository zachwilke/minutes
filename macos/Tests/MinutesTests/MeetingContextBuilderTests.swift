import Foundation
import Testing
@testable import Minutes

struct MeetingContextBuilderTests {
    func meeting(_ title: String, summary: String? = nil, notes: String = "",
                 transcript: String = "", daysAgo: Double = 0) -> Meeting {
        var m = Meeting(title: title, startedAt: Date().addingTimeInterval(-daysAgo * 86_400))
        m.endedAt = m.startedAt.addingTimeInterval(600)
        m.state = .complete
        m.summaryMarkdown = summary
        m.notes = notes
        m.liveTranscript = transcript
        return m
    }

    /// The user's notes were used for ranking but never sent to Claude, so a
    /// meeting that was never summarized was invisible beyond its index line.
    @Test func notesStandInForAMissingSummary() {
        let unsummarized = meeting("Budget", notes: "Agreed to cut the hosting line by 10%")
        let result = MeetingContextBuilder.build(question: "budget hosting", history: [],
                                                 meetings: [unsummarized])
        #expect(result.context.contains("(My notes)"))
        #expect(result.context.contains("cut the hosting line"))
    }

    /// One oversized block near the top used to end the loop, starving every
    /// smaller meeting ranked after it.
    @Test func anOversizedBlockIsSkippedNotFatal() {
        let huge = meeting("Firewall migration", summary: String(repeating: "firewall ", count: 40_000))
        let small = meeting("Firewall follow-up", summary: "Ports 443 and 8443 stay open.", daysAgo: 1)
        let result = MeetingContextBuilder.build(question: "firewall", history: [],
                                                 meetings: [huge, small])
        #expect(result.truncated)
        #expect(result.context.contains("Ports 443 and 8443 stay open."))
        #expect(result.included == [small.id])
    }

    @Test func focusedMeetingComesFirstEvenWhenIrrelevant() {
        let relevant = meeting("SSO rollout", summary: "SSO lands on the ninth.")
        let focused = meeting("Standup", summary: "Nothing blocking.", transcript: "Quiet day.", daysAgo: 3)
        let result = MeetingContextBuilder.build(question: "When is SSO due?", history: [],
                                                 meetings: [relevant, focused], focus: focused.id)
        let focusRange = result.context.range(of: "## The meeting this question is about")
        let otherRange = result.context.range(of: "### SSO rollout")
        #expect(focusRange != nil && otherRange != nil)
        #expect(focusRange!.lowerBound < otherRange!.lowerBound)
        #expect(result.included.first == focused.id)
    }
}
