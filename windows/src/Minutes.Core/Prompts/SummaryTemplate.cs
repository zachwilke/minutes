using Minutes.Core.Meetings;

namespace Minutes.Core.Prompts;

/// <summary>A summary style, from the shared prompt definitions.</summary>
public sealed record SummaryTemplate(string Id, string Name, string Blurb, string Instructions)
{
    public static readonly SummaryTemplate[] All =
        [.. SharedPrompts.Summary.Templates.Select(t =>
            new SummaryTemplate(t.Id, t.Name, t.Blurb, t.Instructions))];

    public static SummaryTemplate Named(string id)
        => All.FirstOrDefault(t => t.Id == id) ?? General;

    public static SummaryTemplate General => Named("general");
}

/// <summary>
/// Builds the summary request.
/// </summary>
/// <remarks>
/// Section order, headings and date formats mirror the macOS implementation
/// exactly. That is not cosmetic: shared/prompts/baseline.txt is the rendered
/// output of both, and the parity test diffs against it, so any drift here shows
/// up as a failing test rather than as two apps quietly writing different notes.
/// </remarks>
public static class SummaryPrompt
{
    /// <summary>Roughly 60k tokens of transcript; a three-hour meeting fits.</summary>
    private const int MaxTranscriptCharacters = 600_000;

    public const string SystemPrompt = SharedPrompts.Summary.SystemPrompt;

    /// <param name="notesLanguage">The language to write in; null follows the meeting.</param>
    /// <param name="wantTitle">Also ask for a title line, for a meeting with only a placeholder name.</param>
    public static string Build(Meeting meeting, SummaryTemplate template, string? notesLanguage = null,
                               bool wantTitle = false, string? userName = null)
    {
        var sections = new List<string>();

        // Swift: "EEEE d MMMM yyyy, HH:mm", local time, en_US_POSIX names.
        string date = PromptFormatting.Format(meeting.StartedAt, "dddd d MMMM yyyy, HH:mm");

        var metadata = new List<string>
        {
            $"- Title: {meeting.DisplayTitle}",
            $"- Date: {date}",
            $"- Duration: {meeting.DurationLabel}"
        };
        if (meeting.DetectedAppName is { } app) metadata.Add($"- Platform: {app}");
        if (meeting.Attendees.Count > 0)
            metadata.Add($"- Invited: {string.Join(", ", meeting.Attendees)}");
        if (userName?.Trim() is { Length: > 0 } name)
        {
            string label = meeting.SpeakerNames is { } names && names.TryGetValue("me", out var mine)
                           && mine.Trim().Length > 0 ? mine.Trim() : "You";
            metadata.Add(SharedPrompts.Summary.RecordedByLine.Replace("{{name}}", name).Replace("{{label}}", label));
        }

        sections.Add($"""
                      # Meeting to summarize

                      ## Metadata
                      {string.Join("\n", metadata)}
                      """);

        // The user's notes come before the transcript deliberately: they set the
        // priorities and the transcript is evidence to flesh them out.
        string notes = meeting.Notes.Trim();
        sections.Add(notes.Length == 0
            ? $"""
               ## My notes
               {SharedPrompts.Summary.NotesNone}
               """
            : $"""
               ## My notes
               {SharedPrompts.Summary.NotesGuidance}

               {Fence(notes)}
               {notes}
               {Fence(notes)}
               """);

        string transcript = Truncate(meeting.TranscriptText);
        string fence = Fence(transcript);
        sections.Add($"""
                      ## Transcript
                      {SharedPrompts.Summary.TranscriptGuidance}

                      {fence}
                      {transcript}
                      {fence}
                      """);

        string produce = $"""
                          ## What to produce
                          {template.Instructions}

                          {SharedPrompts.Summary.ClosingGuidance}
                          """;
        if (notesLanguage is not null)
            produce += "\n\n" + SharedPrompts.Summary.LanguageInstruction.Replace("{{language}}", notesLanguage);
        if (wantTitle)
            produce += "\n\n" + SharedPrompts.Summary.TitleInstruction;
        sections.Add(produce);

        return string.Join("\n\n", sections);
    }

    /// <summary>
    /// A code fence longer than any run of backticks in the text, so content
    /// containing ``` cannot close the block early. Three in the usual case.
    /// </summary>
    public static string Fence(string text)
    {
        int longest = 0, run = 0;
        foreach (char c in text)
        {
            run = c == '`' ? run + 1 : 0;
            longest = Math.Max(longest, run);
        }
        return new string('`', Math.Max(3, longest + 1));
    }

    /// <summary>
    /// Drops the middle of a very long transcript, keeping the opening and the
    /// close — where framing and next steps almost always live.
    /// </summary>
    private static string Truncate(string text)
    {
        if (text.Length <= MaxTranscriptCharacters) return text;
        int keep = MaxTranscriptCharacters / 2;
        return text[..keep]
               + "\n\n[... middle of the transcript omitted because the recording was unusually long ...]\n\n"
               + text[^keep..];
    }
}
