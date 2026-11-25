import Foundation

/// Dumps every prompt the app sends, rendered against fixed fixtures.
///
/// This is the parity test for the shared prompt extraction. The text that
/// steers Claude is the product; if it drifts between platforms, the two apps
/// quietly stop behaving the same. So: capture this output, refactor, capture
/// again, diff. Byte-identical means the refactor changed nothing that matters.
///
/// The Windows port runs the same fixtures against its own generated prompts and
/// diffs against this baseline — which is why the fixtures are fixed values and
/// the timezone is pinned rather than inherited. Nothing here touches the real
/// library or the network.
enum PromptAudit {
    static func dump() -> String {
        // Dates are formatted with the system timezone, so a baseline captured
        // in one zone would not match another machine. Pin it.
        NSTimeZone.default = TimeZone(identifier: "UTC")!

        var out = ""
        func section(_ title: String, _ body: String) {
            out += "===== \(title) =====\n\(body)\n\n"
        }

        section("SUMMARY SYSTEM PROMPT", ClaudeSummarizer.systemPrompt)

        for template in SummaryTemplate.all {
            section("SUMMARY TEMPLATE \(template.id)",
                    "name: \(template.name)\nblurb: \(template.blurb)\ninstructions:\n\(template.instructions)")
        }

        let meeting = Self.fixtureMeeting()
        section("ASSEMBLED SUMMARY PROMPT",
                ClaudeSummarizer.buildPrompt(meeting: meeting,
                                             template: SummaryTemplate.named("client-call")))

        // A meeting with no notes takes the other branch of the notes section.
        var bare = meeting
        bare.notes = ""
        section("ASSEMBLED SUMMARY PROMPT (no notes)",
                ClaudeSummarizer.buildPrompt(meeting: bare, template: .general))

        // Notes containing a code fence get a longer one around them.
        var fenced = meeting
        fenced.notes = "Paste from the runbook:\n```\nnet use Z: \\\\fs01\\share\n```"
        section("MY NOTES (containing a fence)",
                ClaudeSummarizer.buildPrompt(meeting: fenced, template: .general)
                    .components(separatedBy: "## My notes\n").last?
                    .components(separatedBy: "\n\n## Transcript").first ?? "")

        // Notes in a chosen language append one instruction.
        section("WHAT TO PRODUCE (notes in Spanish)",
                ClaudeSummarizer.buildPrompt(meeting: bare, template: .general, notesLanguage: "Spanish")
                    .components(separatedBy: "## What to produce\n").last ?? "")

        // Named speakers replace You / Them everywhere the transcript goes.
        var named = meeting
        named.speakerNames = ["others": "Dana", "me": " "]
        section("TRANSCRIPT (named speakers)", named.transcriptText)

        section("CHAT SYSTEM PROMPT", MeetingChatService.systemPrompt)

        let library = [meeting, Self.fixtureSecondMeeting()]
        let history = [
            ChatMessage(id: Self.fixedID(1), role: .user, text: "What did we agree with Acme?",
                        date: Self.fixedDate, groundedIn: [], isError: false),
            ChatMessage(id: Self.fixedID(2), role: .assistant, text: "They confirmed the renewal.",
                        date: Self.fixedDate, groundedIn: [], isError: false),
            // A failed reply, which must not be replayed to Claude.
            ChatMessage(id: Self.fixedID(3), role: .assistant, text: "Claude reported an error: rate limited",
                        date: Self.fixedDate, groundedIn: [], isError: true)
        ]
        let question = "And when is the SSO work due?"
        let context = MeetingContextBuilder.build(question: question,
                                                  history: history,
                                                  meetings: library)
        section("CHAT CONTEXT", context.context)
        section("ASSEMBLED CHAT PROMPT",
                MeetingChatService.assemble(question: question, history: history,
                                            context: context.context))
        // Asked from inside the second meeting, which outranks nothing on its own.
        section("CHAT CONTEXT (asked about one meeting)",
                MeetingContextBuilder.build(question: question, history: history,
                                            meetings: library, focus: Self.fixedID(11)).context)

        return out
    }

    // MARK: - Fixtures

    /// Fixed epoch — 2026-01-05 14:30:00 UTC.
    private static let fixedStart = Date(timeIntervalSince1970: 1_767_623_400)
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_623_400)

    private static func fixedID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private static func fixtureMeeting() -> Meeting {
        var meeting = Meeting(id: fixedID(10),
                              title: "Acme quarterly review",
                              startedAt: fixedStart)
        meeting.endedAt = fixedStart.addingTimeInterval(32 * 60 + 7)
        meeting.state = .complete
        meeting.detectedAppName = "Microsoft Teams"
        meeting.detectedAppBundleID = "com.microsoft.teams2"
        meeting.attendees = ["Dana Whitfield", "Sam Okafor"]
        meeting.notes = "- renewal timing\n- they want SSO before the new site opens"
        meeting.templateID = "client-call"
        meeting.summaryTemplateID = "client-call"
        meeting.summaryMarkdown = "## Summary\nAcme confirmed the renewal and asked for SSO.\n"
        meeting.segments = [
            TranscriptSegment(id: fixedID(20), start: 0, end: 6.5, speaker: .others,
                              text: "We are happy to renew, but we need single sign-on first."),
            TranscriptSegment(id: fixedID(21), start: 6.5, end: 12, speaker: .me,
                              text: "Understood. We can schedule that for the week of the ninth.")
        ]
        return meeting
    }

    private static func fixtureSecondMeeting() -> Meeting {
        var meeting = Meeting(id: fixedID(11),
                              title: "Internal standup",
                              startedAt: fixedStart.addingTimeInterval(-86_400))
        meeting.endedAt = meeting.startedAt.addingTimeInterval(9 * 60)
        meeting.state = .complete
        meeting.notes = ""
        meeting.summaryMarkdown = "## Per person\nNothing blocking.\n"
        meeting.segments = [
            TranscriptSegment(id: fixedID(22), start: 0, end: 4, speaker: .me,
                              text: "Nothing blocking on my side today.")
        ]
        return meeting
    }
}
