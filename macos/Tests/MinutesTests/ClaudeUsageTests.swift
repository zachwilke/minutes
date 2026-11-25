import Foundation
import Testing
@testable import Minutes

/// What reaches Claude, and how much of it. Recording and transcription never
/// do; summaries and Ask do, and should carry nothing they don't need.
struct ClaudeUsageTests {

    // MARK: - Every run replaces Claude Code's own prompt

    @Test func runsReplaceTheDefaultSystemPrompt() {
        let args = ClaudeInvocation.arguments(systemPrompt: "Summarize.")
        #expect(args.contains("--system-prompt"))
        #expect(!args.contains("--append-system-prompt"))
        #expect(args.contains("--disable-slash-commands"))
        // The isolation flags still come with it.
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--strict-mcp-config"))
        // --bare would skip the keychain, where a subscription sign-in lives.
        #expect(!args.contains("--bare"))
    }

    @Test func askSendsAtMostAboutTwentyThousandTokensOfMeetings() {
        #expect(MeetingContextBuilder.budget == 80_000)
    }

    // MARK: - Titles come with the notes, not from a second run

    private var placeholder: Meeting {
        var meeting = Meeting(title: "Microsoft Teams call, 1:51 PM", startedAt: .now)
        meeting.segments = [TranscriptSegment(start: 0, end: 4, speaker: .others, text: "Let's review the firewall renewal.")]
        return meeting
    }

    @Test func aPlaceholderMeetingAsksForATitleInTheSamePrompt() {
        let prompt = ClaudeSummarizer.buildPrompt(meeting: placeholder, template: .general, wantTitle: true)
        #expect(prompt.hasSuffix(SharedPrompts.Summary.titleInstruction))
        let plain = ClaudeSummarizer.buildPrompt(meeting: placeholder, template: .general)
        #expect(!plain.contains(SharedPrompts.Summary.titleInstruction))
    }

    @Test func theTitleLineIsTakenOffTheNotes() {
        let reply = "Title: Acme firewall renewal\n\n## Summary\nThey renew in March."
        let result = ClaudeSummarizer.splitTitle(reply)
        #expect(result.title == "Acme firewall renewal")
        #expect(result.notes == "## Summary\nThey renew in March.")
    }

    @Test func formattedTitleLinesAreStillRecognised() {
        #expect(ClaudeSummarizer.splitTitle("**Title:** Northwind cutover\n\nNotes").title == "Northwind cutover")
        #expect(ClaudeSummarizer.splitTitle("# Title: Northwind cutover\n\nNotes").notes == "Notes")
    }

    /// A reply that skipped the title line is all notes; nothing is lost.
    @Test func aReplyWithoutATitleIsAllNotes() {
        let reply = "## Summary\nThey renew in March."
        let result = ClaudeSummarizer.splitTitle(reply)
        #expect(result.title == nil)
        #expect(result.notes == reply)
    }
}
