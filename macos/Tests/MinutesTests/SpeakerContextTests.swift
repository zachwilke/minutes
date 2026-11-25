import Foundation
import Testing
@testable import Minutes

/// What Claude is told about who was in a meeting.
struct SpeakerContextTests {
    private var meeting: Meeting {
        var meeting = Meeting(title: "Daily Stand-up", startedAt: .now)
        meeting.attendees = ["Marcus Vale", "Jonah Reed"]
        meeting.segments = [TranscriptSegment(start: 0, end: 3, speaker: .me, text: "Marcus, how's the backlog?")]
        return meeting
    }

    @Test func notesKnowWhoseRecordingItIs() {
        let prompt = ClaudeSummarizer.buildPrompt(meeting: meeting, template: .general, userName: "Alex Rivera")
        #expect(prompt.contains("- Recorded by: Alex Rivera, labelled \"You\" in the transcript"))
        #expect(prompt.contains("- Invited: Marcus Vale, Jonah Reed"))
    }

    /// Named speakers keep their name as the label Claude is pointed at.
    @Test func aNamedMicrophoneIsTheLabelUsed() {
        var named = meeting
        named.speakerNames = ["me": "Alex"]
        let prompt = ClaudeSummarizer.buildPrompt(meeting: named, template: .general, userName: "Alex Rivera")
        #expect(prompt.contains("labelled \"Alex\" in the transcript"))
        #expect(prompt.contains("Alex: Marcus, how's the backlog?"))
    }

    @Test func noNameNoLine() {
        #expect(!ClaudeSummarizer.buildPrompt(meeting: meeting, template: .general).contains("Recorded by"))
        #expect(!ClaudeSummarizer.buildPrompt(meeting: meeting, template: .general, userName: "  ").contains("Recorded by"))
    }

    @Test func theGuidanceAllowsReattributingQuietCallVoices() {
        #expect(SharedPrompts.Summary.transcriptGuidance.contains("labelled \"You\" while I was not speaking"))
    }

    @Test func askKnowsWhoIsAsking() {
        let prompt = MeetingChatService.assemble(question: "What did I promise Marcus?", history: [],
                                                 context: "(meetings)", userName: "Alex Rivera")
        #expect(prompt.hasPrefix("# About the user\nThe user is Alex Rivera."))
        #expect(!MeetingChatService.assemble(question: "q", history: [], context: "c").contains("About the user"))
    }
}
