using System.Text;
using Minutes.Core.Audio;
using Minutes.Core.Meetings;

namespace Minutes.Core.Prompts;

/// <summary>
/// Renders every prompt against fixed fixtures, for comparison with
/// shared/prompts/baseline.txt.
/// </summary>
/// <remarks>
/// This is the cross-platform prompt contract. The fixtures and their values
/// mirror the macOS PromptAudit exactly; if this output diverges by a byte, the
/// two apps have started steering Claude differently and the parity test fails.
/// </remarks>
public static class PromptAudit
{
    /// <summary>2026-01-05 14:30:00 UTC — the same instant macOS uses.</summary>
    private static readonly DateTimeOffset FixedStart = DateTimeOffset.FromUnixTimeSeconds(1_767_623_400);

    public static string Dump()
    {
        // Pinned like macOS pins NSTimeZone.default, so the baseline does not
        // depend on the machine's time zone. Restored afterwards.
        var zone = PromptFormatting.TimeZone;
        PromptFormatting.TimeZone = TimeZoneInfo.Utc;
        try { return DumpPinned(); }
        finally { PromptFormatting.TimeZone = zone; }
    }

    private static string DumpPinned()
    {
        var output = new StringBuilder();
        void Section(string title, string body)
            => output.Append("===== ").Append(title).Append(" =====\n").Append(body).Append("\n\n");

        Section("SUMMARY SYSTEM PROMPT", SummaryPrompt.SystemPrompt);

        foreach (var template in SummaryTemplate.All)
            Section($"SUMMARY TEMPLATE {template.Id}",
                    $"name: {template.Name}\nblurb: {template.Blurb}\ninstructions:\n{template.Instructions}");

        var meeting = FixtureMeeting();
        Section("ASSEMBLED SUMMARY PROMPT",
                SummaryPrompt.Build(meeting, SummaryTemplate.Named("client-call")));

        // A meeting with no notes takes the other branch of the notes section.
        var bare = FixtureMeeting();
        bare.Notes = "";
        Section("ASSEMBLED SUMMARY PROMPT (no notes)",
                SummaryPrompt.Build(bare, SummaryTemplate.General));

        // Notes containing a code fence get a longer one around them.
        var fenced = FixtureMeeting();
        fenced.Notes = "Paste from the runbook:\n```\nnet use Z: \\\\fs01\\share\n```";
        Section("MY NOTES (containing a fence)",
                SummaryPrompt.Build(fenced, SummaryTemplate.General)
                    .Split("## My notes\n")[^1]
                    .Split("\n\n## Transcript")[0]);

        // Notes in a chosen language append one instruction.
        Section("WHAT TO PRODUCE (notes in Spanish)",
                SummaryPrompt.Build(bare, SummaryTemplate.General, "Spanish")
                    .Split("## What to produce\n")[^1]);

        // Named speakers replace You / Them everywhere the transcript goes.
        var named = FixtureMeeting();
        named.SpeakerNames = new() { ["others"] = "Dana", ["me"] = " " };
        Section("TRANSCRIPT (named speakers)", named.TranscriptText);

        Section("CHAT SYSTEM PROMPT", ChatPrompt.SystemPrompt);

        var library = new List<Meeting> { meeting, FixtureSecondMeeting() };
        var history = new List<ChatMessage>
        {
            new(FixedId(1), ChatRole.User, "What did we agree with Acme?", FixedStart),
            new(FixedId(2), ChatRole.Assistant, "They confirmed the renewal.", FixedStart),
            // A failed reply, which must not be replayed to Claude.
            new(FixedId(3), ChatRole.Assistant, "Claude reported an error: rate limited", FixedStart) { IsError = true }
        };
        const string question = "And when is the SSO work due?";
        var context = ChatContextBuilder.Build(question, history, library);
        Section("CHAT CONTEXT", context.Context);
        Section("ASSEMBLED CHAT PROMPT", ChatPrompt.Assemble(question, history, context.Context));
        // Asked from inside the second meeting, which outranks nothing on its own.
        Section("CHAT CONTEXT (asked about one meeting)",
                ChatContextBuilder.Build(question, history, library, FixedId(11)).Context);

        return output.ToString();
    }

    private static Guid FixedId(int n) => Guid.Parse($"00000000-0000-0000-0000-{n:D12}");

    private static Meeting FixtureMeeting() => new()
    {
        Id = FixedId(10),
        Title = "Acme quarterly review",
        StartedAt = FixedStart,
        EndedAt = FixedStart.AddSeconds(32 * 60 + 7),
        State = MeetingState.Complete,
        DetectedAppName = "Microsoft Teams",
        DetectedAppBundleId = "com.microsoft.teams2",
        Attendees = ["Dana Whitfield", "Sam Okafor"],
        Notes = "- renewal timing\n- they want SSO before the new site opens",
        TemplateId = "client-call",
        SummaryTemplateId = "client-call",
        SummaryMarkdown = "## Summary\nAcme confirmed the renewal and asked for SSO.\n",
        Segments =
        [
            new TranscriptSegment { Id = FixedId(20), Start = 0, End = 6.5, Speaker = Speaker.Others,
                Text = "We are happy to renew, but we need single sign-on first." },
            new TranscriptSegment { Id = FixedId(21), Start = 6.5, End = 12, Speaker = Speaker.Me,
                Text = "Understood. We can schedule that for the week of the ninth." }
        ]
    };

    private static Meeting FixtureSecondMeeting() => new()
    {
        Id = FixedId(11),
        Title = "Internal standup",
        StartedAt = FixedStart.AddSeconds(-86_400),
        EndedAt = FixedStart.AddSeconds(-86_400 + 9 * 60),
        State = MeetingState.Complete,
        Notes = "",
        SummaryMarkdown = "## Per person\nNothing blocking.\n",
        Segments =
        [
            new TranscriptSegment { Id = FixedId(22), Start = 0, End = 4, Speaker = Speaker.Me,
                Text = "Nothing blocking on my side today." }
        ]
    };
}
