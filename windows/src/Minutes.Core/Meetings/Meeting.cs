using System.Text.Json;
using System.Text.Json.Serialization;
using Minutes.Core.Audio;

namespace Minutes.Core.Meetings;

[JsonConverter(typeof(MeetingStateConverter))]
public enum MeetingState { Recording, Transcribing, Summarizing, Complete, Failed }

/// <summary>A timestamped chunk of refined transcript.</summary>
public sealed class TranscriptSegment
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("start")] public double Start { get; set; }
    [JsonPropertyName("end")] public double End { get; set; }
    [JsonPropertyName("speaker")]
    [JsonConverter(typeof(SpeakerConverter))]
    public Speaker Speaker { get; set; } = Speaker.Unknown;
    [JsonPropertyName("text")] public string Text { get; set; } = "";

    [JsonIgnore]
    public string TimestampLabel
    {
        get
        {
            int total = (int)Start;
            return $"{total / 60:00}:{total % 60:00}";
        }
    }

    [JsonIgnore]
    public string SpeakerLabel => Speaker switch
    {
        Speaker.Me => "You",
        Speaker.Others => "Them",
        _ => "Speaker"
    };
}

/// <summary>
/// One meeting. The JSON shape is the cross-platform contract — see
/// shared/spec/meeting-format.md — so property names match the macOS app's
/// exactly, including the ones that are not plain camelCase (templateID).
/// </summary>
public sealed class Meeting
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("startedAt")]
    [JsonConverter(typeof(SwiftIso8601Converter))]
    public DateTimeOffset StartedAt { get; set; }
    [JsonPropertyName("endedAt")]
    [JsonConverter(typeof(NullableSwiftIso8601Converter))]
    public DateTimeOffset? EndedAt { get; set; }
    [JsonPropertyName("state")] public MeetingState State { get; set; } = MeetingState.Recording;

    [JsonPropertyName("detectedAppBundleID")] public string? DetectedAppBundleId { get; set; }
    [JsonPropertyName("detectedAppName")] public string? DetectedAppName { get; set; }
    [JsonPropertyName("calendarEventTitle")] public string? CalendarEventTitle { get; set; }
    [JsonPropertyName("attendees")] public List<string> Attendees { get; set; } = [];
    /// <summary>Invitees' addresses, excluding the user's own.</summary>
    [JsonPropertyName("attendeeEmails")] public List<string>? AttendeeEmails { get; set; }
    /// <summary>Folder name; null means unfiled.</summary>
    [JsonPropertyName("folder")] public string? Folder { get; set; }
    /// <summary>Names the user gave the two sides, keyed "me" / "others" / "unknown".</summary>
    [JsonPropertyName("speakerNames")] public Dictionary<string, string>? SpeakerNames { get; set; }

    [JsonPropertyName("notes")] public string Notes { get; set; } = "";
    [JsonPropertyName("liveTranscript")] public string LiveTranscript { get; set; } = "";
    [JsonPropertyName("segments")] public List<TranscriptSegment> Segments { get; set; } = [];

    [JsonPropertyName("summaryMarkdown")] public string? SummaryMarkdown { get; set; }
    [JsonPropertyName("templateID")] public string TemplateId { get; set; } = "general";
    [JsonPropertyName("summaryTemplateID")] public string? SummaryTemplateId { get; set; }
    /// <summary>Set when the user edits the generated notes; regenerating warns first.</summary>
    [JsonPropertyName("summaryEditedAt")]
    [JsonConverter(typeof(NullableSwiftIso8601Converter))]
    public DateTimeOffset? SummaryEditedAt { get; set; }
    [JsonPropertyName("failureReason")] public string? FailureReason { get; set; }

    /// <summary>
    /// Fields this build does not know — written by a newer build or the other
    /// platform — kept so that saving a meeting never silently drops them.
    /// </summary>
    [JsonExtensionData] public Dictionary<string, JsonElement>? UnknownFields { get; set; }

    [JsonIgnore]
    public TimeSpan Duration => (EndedAt ?? DateTimeOffset.UtcNow) - StartedAt;

    /// <summary>
    /// Matches the macOS formatting exactly — the prompts embed it, so a
    /// different rendering here would break prompt parity.
    /// </summary>
    [JsonIgnore]
    public string DurationLabel
    {
        get
        {
            int total = (int)Duration.TotalSeconds;
            if (total >= 3600) return $"{total / 3600}h {(total % 3600) / 60:00}m";
            if (total >= 60) return $"{total / 60}m {total % 60:00}s";
            return $"{total}s";
        }
    }

    [JsonIgnore]
    public string DisplayTitle
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(Title)) return Title;
            if (!string.IsNullOrEmpty(CalendarEventTitle)) return CalendarEventTitle!;
            return "Meeting";
        }
    }

    /// <summary>Best available transcript, preferring the refined segments.</summary>
    [JsonIgnore]
    public string TranscriptText => Segments.Count == 0
        ? LiveTranscript
        : string.Join("\n", Segments.Select(s => $"[{s.TimestampLabel}] {LabelFor(s)}: {s.Text}"));

    /// <summary>A segment's speaker label: the user's name for that side, else the default.</summary>
    public string LabelFor(TranscriptSegment segment)
    {
        string key = segment.Speaker switch
        {
            Speaker.Me => "me",
            Speaker.Others => "others",
            _ => "unknown"
        };
        string name = SpeakerNames is { } names && names.TryGetValue(key, out var n) ? n.Trim() : "";
        return name.Length == 0 ? segment.SpeakerLabel : name;
    }

    [JsonIgnore]
    public bool SummaryIsStale =>
        !string.IsNullOrEmpty(SummaryMarkdown)
        && SummaryTemplateId is not null
        && SummaryTemplateId != TemplateId;
}

/// <summary>
/// Source-generated serialisation. Reflection-based JsonSerializer is not
/// AOT-safe, and the plan commits to Native AOT for the launch and memory
/// budgets — so the shape is generated at compile time instead.
/// </summary>
[JsonSourceGenerationOptions(WriteIndented = true,
                             DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(Meeting))]
internal partial class MeetingJsonContext : JsonSerializerContext;

/// <summary>
/// Reading and writing meeting.json, compatible with the macOS app.
/// </summary>
public static class MeetingJson
{
    public static Meeting Read(string path)
        => JsonSerializer.Deserialize(File.ReadAllText(path), MeetingJsonContext.Default.Meeting)
           ?? throw new InvalidDataException($"{path} is not a meeting");

    public static string Serialize(Meeting meeting)
        => JsonSerializer.Serialize(meeting, MeetingJsonContext.Default.Meeting);

    public static void Write(Meeting meeting, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        // Write beside, then move: a crash mid-write must not truncate an
        // existing meeting's metadata.
        string temporary = path + ".tmp";
        File.WriteAllText(temporary, Serialize(meeting));
        File.Move(temporary, path, overwrite: true);
    }
}

/// <summary>Exact strings Swift writes for MeetingState.</summary>
internal sealed class MeetingStateConverter : JsonConverter<MeetingState>
{
    public override MeetingState Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        => reader.GetString() switch
        {
            "recording" => MeetingState.Recording,
            "transcribing" => MeetingState.Transcribing,
            "summarizing" => MeetingState.Summarizing,
            "complete" => MeetingState.Complete,
            "failed" => MeetingState.Failed,
            var other => throw new JsonException($"unknown meeting state '{other}'")
        };

    public override void Write(Utf8JsonWriter writer, MeetingState value, JsonSerializerOptions options)
        => writer.WriteStringValue(value switch
        {
            MeetingState.Recording => "recording",
            MeetingState.Transcribing => "transcribing",
            MeetingState.Summarizing => "summarizing",
            MeetingState.Complete => "complete",
            _ => "failed"
        });
}

/// <summary>Exact strings Swift writes for Speaker.</summary>
internal sealed class SpeakerConverter : JsonConverter<Speaker>
{
    public override Speaker Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        => reader.GetString() switch
        {
            "me" => Speaker.Me,
            "others" => Speaker.Others,
            _ => Speaker.Unknown
        };

    public override void Write(Utf8JsonWriter writer, Speaker value, JsonSerializerOptions options)
        => writer.WriteStringValue(value switch
        {
            Speaker.Me => "me",
            Speaker.Others => "others",
            _ => "unknown"
        });
}

/// <summary>
/// Swift's `.iso8601` strategy emits second precision with a Z suffix
/// ("2026-08-31T17:46:47Z"). System.Text.Json would otherwise write fractional
/// seconds and an offset, which macOS then fails to decode.
/// </summary>
internal sealed class SwiftIso8601Converter : JsonConverter<DateTimeOffset>
{
    private const string Format = "yyyy-MM-ddTHH:mm:ssZ";

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        => DateTimeOffset.Parse(reader.GetString()!, System.Globalization.CultureInfo.InvariantCulture,
                                System.Globalization.DateTimeStyles.AssumeUniversal
                                | System.Globalization.DateTimeStyles.AdjustToUniversal);

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
        => writer.WriteStringValue(value.ToUniversalTime()
            .ToString(Format, System.Globalization.CultureInfo.InvariantCulture));
}

internal sealed class NullableSwiftIso8601Converter : JsonConverter<DateTimeOffset?>
{
    private readonly SwiftIso8601Converter _inner = new();

    public override DateTimeOffset? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options)
        => reader.TokenType == JsonTokenType.Null ? null : _inner.Read(ref reader, typeof(DateTimeOffset), options);

    public override void Write(Utf8JsonWriter writer, DateTimeOffset? value, JsonSerializerOptions options)
    {
        if (value is null) writer.WriteNullValue();
        else _inner.Write(writer, value.Value, options);
    }
}
