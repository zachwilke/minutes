using System.Text.Json;
using Minutes.Core.Meetings;

namespace Minutes.Core.Tests;

/// <summary>
/// The storage format is the cross-platform contract: a library written on a Mac
/// must open on a PC. Verified against a meeting.json the shipping macOS app
/// actually wrote, not against our own output.
/// </summary>
public class MeetingFormatTests
{
    private static string Fixture(string name) => Path.Combine(AppContext.BaseDirectory, "fixtures", name);

    [Fact]
    public void ReadsAMeetingWrittenByMacOS()
    {
        var meeting = MeetingJson.Read(Fixture("macos-meeting.json"));

        Assert.Equal(MeetingState.Complete, meeting.State);
        Assert.Equal("Meeting at 12:46", meeting.Title);
        Assert.Equal("discovery", meeting.TemplateId);
        Assert.Equal(new DateTimeOffset(2026, 8, 31, 17, 46, 47, TimeSpan.Zero), meeting.StartedAt);
        Assert.NotNull(meeting.EndedAt);

        // Segment shape, including the speaker enum's wire string.
        var segment = Assert.Single(meeting.Segments);
        Assert.Equal(Speaker.Me, segment.Speaker);
        Assert.Equal(0, segment.Start);
        Assert.Contains("Test, test, test", segment.Text);

        // Absent optionals must decode as null rather than throwing.
        Assert.Null(meeting.DetectedAppName);
        Assert.Null(meeting.FailureReason);
        Assert.NotNull(meeting.SummaryMarkdown);
    }

    [Fact]
    public void ComputedFieldsMatchWhatTheMacAppWouldShow()
    {
        var meeting = MeetingJson.Read(Fixture("macos-meeting.json"));
        // The recording ran 7 seconds; the prompts embed this string, so its
        // formatting is part of the contract.
        Assert.Equal("7s", meeting.DurationLabel);
        Assert.Equal("[00:00] You: " + meeting.Segments[0].Text, meeting.TranscriptText);
    }

    [Fact]
    public void RoundTripsWithoutLosingOrInventingFields()
    {
        string original = File.ReadAllText(Fixture("macos-meeting.json"));
        var meeting = MeetingJson.Read(Fixture("macos-meeting.json"));
        string written = MeetingJson.Serialize(meeting);

        using var before = JsonDocument.Parse(original);
        using var after = JsonDocument.Parse(written);

        var beforeKeys = before.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(n => n);
        var afterKeys = after.RootElement.EnumerateObject().Select(p => p.Name).OrderBy(n => n);

        // No key may be dropped, and none invented — a nulled-out optional
        // written as an explicit null would trip Swift's decoder.
        Assert.Equal(beforeKeys, afterKeys);

        // And the values that matter must survive verbatim.
        Assert.Equal(before.RootElement.GetProperty("startedAt").GetString(),
                     after.RootElement.GetProperty("startedAt").GetString());
        Assert.Equal(before.RootElement.GetProperty("state").GetString(),
                     after.RootElement.GetProperty("state").GetString());
        Assert.Equal(before.RootElement.GetProperty("segments")[0].GetProperty("speaker").GetString(),
                     after.RootElement.GetProperty("segments")[0].GetProperty("speaker").GetString());
    }

    [Fact]
    public void WritesDatesInSwiftsIso8601Shape()
    {
        // Swift's .iso8601 decoder rejects fractional seconds and offsets, so
        // the exact rendering matters more than it looks.
        var meeting = new Meeting
        {
            Title = "x",
            StartedAt = new DateTimeOffset(2026, 1, 5, 14, 30, 0, TimeSpan.Zero),
            EndedAt = new DateTimeOffset(2026, 1, 5, 14, 31, 2, 500, TimeSpan.Zero)
        };
        using var document = JsonDocument.Parse(MeetingJson.Serialize(meeting));
        Assert.Equal("2026-01-05T14:30:00Z", document.RootElement.GetProperty("startedAt").GetString());
        Assert.Equal("2026-01-05T14:31:02Z", document.RootElement.GetProperty("endedAt").GetString());
    }

    [Fact]
    public void LoadsALibraryWrittenByMacOS()
    {
        // The phase-2 acceptance criterion: a macOS-created library lists. Built
        // from the checked-in macOS fixture rather than read from the developer's
        // own library — that version passed silently on any machine without one.
        string root = Path.Combine(Path.GetTempPath(), $"library-{Guid.NewGuid():N}");
        string json = File.ReadAllText(Fixture("macos-meeting.json"));
        using (var document = JsonDocument.Parse(json))
        {
            string id = document.RootElement.GetProperty("id").GetString()!;
            string directory = Path.Combine(root, "Meetings", id.ToUpperInvariant());
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, "meeting.json"), json);
        }
        // A second, older meeting, to check ordering.
        string olderId = Guid.NewGuid().ToString().ToUpperInvariant();
        Directory.CreateDirectory(Path.Combine(root, "Meetings", olderId));
        File.WriteAllText(Path.Combine(root, "Meetings", olderId, "meeting.json"),
            $$"""{"id":"{{olderId}}","title":"Older","startedAt":"2020-01-01T00:00:00Z"}""");

        string previous = AppPaths.SupportRoot;
        try
        {
            AppPaths.SupportRoot = root;
            var meetings = MeetingLibrary.LoadAll();
            Assert.Equal(2, meetings.Count);
            Assert.True(meetings[0].StartedAt >= meetings[1].StartedAt, "newest first");
            Assert.Equal("Older", meetings[1].Title);
            Assert.All(meetings, m => Assert.NotEqual(Guid.Empty, m.Id));
        }
        finally
        {
            AppPaths.SupportRoot = previous;
            Directory.Delete(root, recursive: true);
        }
    }
}
