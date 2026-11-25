using Minutes.Core.Meetings;

namespace Minutes.Core.Prompts;

public enum ChatRole { User, Assistant }

public sealed record ChatMessage(Guid Id, ChatRole Role, string Text, DateTimeOffset Date)
{
    public List<Guid> GroundedIn { get; init; } = [];
    public bool IsError { get; init; }
}

public sealed record ChatContext(string Context, List<Guid> Included, int IndexedCount, bool Truncated);

/// <summary>
/// Chooses what Claude sees when answering a question about the library.
/// </summary>
/// <remarks>
/// Ported from the macOS implementation, weights and all. The layering is the
/// point: every meeting always appears in a compact index, so questions like
/// "when did I last speak to them?" are answerable, and full detail is added in
/// relevance order until a character budget runs out. Sending only the top
/// matches would make the model blind to what it was not given.
/// </remarks>
public static class ChatContextBuilder
{
    public const int Budget = 80_000;

    /// <summary>Words too common to discriminate between meetings.</summary>
    private static readonly HashSet<string> StopWords =
    [
        "the", "and", "for", "with", "that", "this", "what", "when", "where", "who",
        "how", "did", "was", "were", "are", "you", "your", "our", "about", "from",
        "have", "has", "had", "said", "say", "tell", "any", "all", "can", "could",
        "would", "should", "there", "their", "they", "them", "then", "than", "into",
        "meeting", "meetings", "call", "calls", "discuss", "discussed", "talk",
        "talked", "mentioned", "last", "which", "been", "being", "does", "just"
    ];

    /// <param name="focus">The meeting a question is asked from inside of. Its
    /// notes and transcript always come first, in full, ahead of anything ranked.</param>
    public static ChatContext Build(string question, IReadOnlyList<ChatMessage> history,
                                    IReadOnlyList<Meeting> meetings, Guid? focus = null)
    {
        if (meetings.Count == 0)
            return new ChatContext("The meeting library is empty.", [], 0, false);

        var terms = SearchTerms(question, history);
        // Ties break to the more recent meeting, which is almost always what
        // someone means by "the" meeting about something.
        var ranked = meetings
            .Select(m => (Meeting: m, Score: Relevance(m, terms)))
            .OrderByDescending(x => x.Score)
            .ThenByDescending(x => x.Meeting.StartedAt)
            .ToList();

        var sections = new List<string>();
        var included = new List<Guid>();
        int used = 0;
        bool truncated = false;

        string index = IndexSection(meetings);
        sections.Add(index);
        used += index.Length;

        // The meeting being asked about, before anything competes for budget.
        var focused = focus is { } id ? meetings.FirstOrDefault(m => m.Id == id) : null;
        if (focused is not null)
        {
            var blocks = new List<string>();
            if (NotesBody(focused) is var (text, label))
                blocks.Add(DetailBlock(focused, text, label));
            if (focused.TranscriptText.Length > 0)
                blocks.Add(DetailBlock(focused, focused.TranscriptText, "Transcript"));
            string section = "## The meeting this question is about\n\n" + string.Join("\n\n", blocks);
            if (blocks.Count > 0 && used + section.Length <= Budget)
            {
                sections.Add(section);
                included.Add(focused.Id);
                used += section.Length;
            }
        }
        var others = ranked.Where(x => x.Meeting.Id != focused?.Id).ToList();

        // A meeting without a summary contributes the user's own notes. A block
        // that does not fit is skipped, not the end of the loop: one huge entry
        // near the top must not starve every smaller one after it.
        var summaries = new List<string>();
        foreach (var entry in others)
        {
            if (NotesBody(entry.Meeting) is not var (body, bodyLabel)) continue;
            string block = DetailBlock(entry.Meeting, body, bodyLabel);
            if (used + block.Length > Budget) { truncated = true; continue; }
            summaries.Add(block);
            included.Add(entry.Meeting.Id);
            used += block.Length;
        }
        if (summaries.Count > 0)
            sections.Add("## Notes from these meetings\n\n" + string.Join("\n\n", summaries));

        // Transcripts only once every summary fits — notes are the more useful
        // text per character, so they get the budget first.
        if (!truncated)
        {
            var transcripts = new List<string>();
            foreach (var entry in others)
            {
                string transcript = entry.Meeting.TranscriptText;
                if (transcript.Length == 0) continue;
                string block = DetailBlock(entry.Meeting, transcript, "Transcript");
                if (used + block.Length > Budget) { truncated = true; continue; }
                transcripts.Add(block);
                if (!included.Contains(entry.Meeting.Id)) included.Add(entry.Meeting.Id);
                used += block.Length;
            }
            if (transcripts.Count > 0)
                sections.Add("## Full transcripts\n\n" + string.Join("\n\n", transcripts));
        }

        if (truncated)
            sections.Add($"""
                          ## Coverage
                          {SharedPrompts.Chat.CoverageNote}
                          """);

        return new ChatContext(string.Join("\n\n", sections), included, meetings.Count, truncated);
    }

    /// <summary>
    /// Every meeting, compactly. This is what lets Claude count, compare dates,
    /// and notice a meeting whose detail was not included.
    /// </summary>
    private static string IndexSection(IReadOnlyList<Meeting> meetings)
    {
        var rows = meetings
            .OrderByDescending(m => m.StartedAt)
            .Select(meeting =>
            {
                string row = $"- {Stamp(meeting)} · {meeting.DurationLabel} · {meeting.DisplayTitle}";
                if (meeting.DetectedAppName is { } app) row += $" · {app}";
                if (meeting.Attendees.Count > 0)
                    row += $" · invited: {string.Join(", ", meeting.Attendees)}";
                if (FirstLine(meeting.SummaryMarkdown) is { } first) row += $"\n    {first}";
                else if (meeting.State == MeetingState.Failed)
                    row += $"\n    (not transcribed: {meeting.FailureReason ?? "unknown"})";
                return row;
            });

        return $"""
                ## Every meeting in the library ({meetings.Count})
                {SharedPrompts.Chat.IndexNote}

                {string.Join("\n", rows)}
                """;
    }

    /// <summary>The best prose for a meeting: its summary, else the user's own notes.</summary>
    private static (string Text, string Label)? NotesBody(Meeting meeting)
    {
        if (!string.IsNullOrEmpty(meeting.SummaryMarkdown)) return (meeting.SummaryMarkdown!, "Notes");
        string notes = meeting.Notes.Trim();
        return notes.Length == 0 ? null : (notes, "My notes");
    }

    private static string DetailBlock(Meeting meeting, string body, string label)
        => $"""
            ### {meeting.DisplayTitle} — {Stamp(meeting)} ({label})

            {body}
            """;

    private static string Stamp(Meeting meeting)
        => PromptFormatting.Format(meeting.StartedAt, "yyyy-MM-dd HH:mm");

    /// <summary>Skips headings to reach the first real sentence.</summary>
    private static string? FirstLine(string? markdown)
    {
        if (markdown is null) return null;
        foreach (var line in markdown.Split('\n'))
        {
            string trimmed = line.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith('#') || trimmed.StartsWith('|')) continue;
            return trimmed.Length > 180 ? trimmed[..180] : trimmed;
        }
        return null;
    }

    /// <summary>
    /// Terms from the question, plus the user's recent turns so a follow-up like
    /// "and what did they decide?" still retrieves the right meeting.
    /// </summary>
    private static List<string> SearchTerms(string question, IReadOnlyList<ChatMessage> history)
    {
        var recent = history.TakeLast(4).Where(m => m.Role == ChatRole.User).Select(m => m.Text);
        string text = string.Join(" ", new[] { question }.Concat(recent));
        var words = text.ToLowerInvariant()
            .Split((char[])['\0'], StringSplitOptions.None)[0]
            .Select(c => char.IsLetterOrDigit(c) ? c : ' ')
            .Aggregate(new System.Text.StringBuilder(), (sb, c) => sb.Append(c))
            .ToString()
            .Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Where(w => w.Length >= 3 && !StopWords.Contains(w));
        return [.. words.Distinct()];
    }

    /// <summary>
    /// Weighted keyword overlap — no embeddings, nothing to index — weighted by
    /// how deliberate each field is: a term in a title or in the user's own notes
    /// means far more than one buried in a transcript.
    /// </summary>
    private static int Relevance(Meeting meeting, List<string> terms)
    {
        if (terms.Count == 0) return 0;
        string title = meeting.DisplayTitle.ToLowerInvariant();
        string attendees = string.Join(" ", meeting.Attendees).ToLowerInvariant();
        string notes = meeting.Notes.ToLowerInvariant();
        string summary = (meeting.SummaryMarkdown ?? "").ToLowerInvariant();
        string transcript = meeting.TranscriptText.ToLowerInvariant();

        int score = 0;
        foreach (var term in terms)
        {
            if (title.Contains(term)) score += 8;
            if (attendees.Contains(term)) score += 6;
            if (notes.Contains(term)) score += 4;
            if (summary.Contains(term)) score += 3;
            // Repeats carry signal, but with diminishing returns so one long
            // meeting cannot dominate.
            int mentions = CountOccurrences(transcript, term);
            if (mentions > 0) score += Math.Min(mentions, 5);
        }
        return score;
    }

    private static int CountOccurrences(string haystack, string needle)
    {
        int count = 0, index = 0;
        while ((index = haystack.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += needle.Length;
        }
        return count;
    }
}

/// <summary>Assembles the chat request around the retrieved context.</summary>
public static class ChatPrompt
{
    public const string SystemPrompt = SharedPrompts.Chat.SystemPrompt;

    public static string Assemble(string question, IReadOnlyList<ChatMessage> history, string context,
                                  string? userName = null)
    {
        var parts = new List<string>();
        if (userName?.Trim() is { Length: > 0 } name)
            parts.Add(SharedPrompts.Chat.UserLine.Replace("{{name}}", name));
        parts.Add($"# The user's meeting library\n\n{context}");

        // Bounded: a long thread would otherwise crowd out the meeting content,
        // which matters more. Failed and empty replies are left out: replaying
        // an error to Claude as its own earlier answer only confuses it.
        var recent = history
            .Where(m => !m.IsError && m.Text.Trim().Length > 0)
            .TakeLast(12)
            .ToList();
        if (recent.Count > 0)
        {
            var turns = recent.Select(m => $"{(m.Role == ChatRole.User ? "User" : "You")}: {m.Text}");
            parts.Add($"""
                       # Conversation so far
                       {string.Join("\n\n", turns)}
                       """);
        }

        parts.Add($"""
                   # The user's question
                   {question}
                   """);

        return string.Join("\n\n", parts);
    }
}
