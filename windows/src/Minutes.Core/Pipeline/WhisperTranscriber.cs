using System.Text.Json;
using Minutes.Core.Audio;
using Minutes.Core.Meetings;

namespace Minutes.Core.Pipeline;

/// <summary>
/// Runs the recorded audio through whisper.cpp, then labels each segment using
/// the recorded mic-versus-system energy.
/// </summary>
/// <remarks>
/// On Windows the binary is bundled with the app rather than installed through a
/// package manager, which removes a whole setup step the Mac needs. The JSON
/// shape (millisecond offsets under "transcription") is whisper.cpp's own and is
/// the same on both platforms.
/// </remarks>
public sealed class WhisperTranscriber
{
    public string? ExecutablePath { get; init; }
    public string? ModelPath { get; init; }
    public Action<double>? OnProgress { get; init; }

    /// <summary>Prefers the most capable model present.</summary>
    public static string? FindModel()
    {
        if (!Directory.Exists(AppPaths.ModelsRoot)) return null;
        string[] ranking = ["large-v3-turbo", "large-v3", "large", "medium", "small", "base", "tiny"];

        return Directory.EnumerateFiles(AppPaths.ModelsRoot, "*.bin")
            .Select(path => (Path: path, Name: Path.GetFileName(path).ToLowerInvariant()))
            // Homebrew ships a truncated test stub that cannot transcribe.
            .Select(x => (x.Path, Rank: x.Name.Contains("for-tests")
                ? ranking.Length + 1
                : Array.FindIndex(ranking, key => x.Name.Contains(key)) is var i && i >= 0 ? i : ranking.Length))
            .OrderBy(x => x.Rank).ThenBy(x => x.Path)
            .Select(x => x.Path)
            .FirstOrDefault();
    }

    public async Task<List<TranscriptSegment>> TranscribeAsync(
        string audioPath, EnergyTrack energy, CancellationToken cancellationToken = default)
    {
        string executable = ExecutablePath ?? ProcessRunner.Locate("whisper-cli")
            ?? throw new FileNotFoundException(
                "whisper-cli was not found. On Windows it ships with the app; check the install.");
        string model = ModelPath ?? FindModel()
            ?? throw new FileNotFoundException(
                $"No Whisper model was found in {AppPaths.ModelsRoot}.");

        string outputBase = Path.Combine(Path.GetDirectoryName(audioPath)!,
                                         Path.GetFileNameWithoutExtension(audioPath) + ".whisper");
        string jsonPath = outputBase + ".json";
        if (File.Exists(jsonPath)) File.Delete(jsonPath);

        int threads = Math.Max(4, Environment.ProcessorCount - 2);
        string[] arguments =
        [
            "-m", model,
            "-f", audioPath,
            "-of", outputBase,
            "-oj",                     // JSON with millisecond offsets
            "-l", "auto",              // meetings are not always in English
            "-t", threads.ToString(),
            "-pp",                     // progress on stderr, for the UI
            "-ml", "0"
        ];

        int lastPercent = -1;
        var result = await ProcessRunner.RunAsync(executable, arguments,
            timeout: TimeSpan.FromHours(2),
            onStandardErrorLine: line =>
            {
                if (ParseProgress(line) is not { } value) return;
                // Quantised: publishing every stderr line would drive a UI update
                // per line for the whole transcription.
                int percent = (int)(value * 100);
                if (percent == lastPercent) return;
                lastPercent = percent;
                OnProgress?.Invoke(value);
            },
            cancellationToken: cancellationToken);

        if (result.ExitCode != 0)
            throw new InvalidOperationException(
                $"whisper-cli exited with {result.ExitCode}. {Tail(result.StandardError)}");

        var segments = ParseSegments(jsonPath, energy);
        if (segments.Count == 0)
            throw new InvalidOperationException("Whisper produced no transcript for this recording.");
        return Merge(segments);
    }

    private static List<TranscriptSegment> ParseSegments(string jsonPath, EnergyTrack energy)
    {
        var segments = new List<TranscriptSegment>();
        if (!File.Exists(jsonPath)) return segments;

        using var document = JsonDocument.Parse(File.ReadAllText(jsonPath));
        if (!document.RootElement.TryGetProperty("transcription", out var entries)) return segments;
        // Once per recording: estimating it scans every frame.
        float echoCoupling = energy.EchoCoupling();

        foreach (var entry in entries.EnumerateArray())
        {
            string text = (entry.TryGetProperty("text", out var t) ? t.GetString() ?? "" : "").Trim();
            if (text.Length == 0 || IsNoiseMarker(text)) continue;

            double start = 0, end = 0;
            if (entry.TryGetProperty("offsets", out var offsets)
                && offsets.TryGetProperty("from", out var from)
                && offsets.TryGetProperty("to", out var to))
            {
                start = from.GetDouble() / 1000.0;
                end = to.GetDouble() / 1000.0;
            }
            else if (entry.TryGetProperty("timestamps", out var stamps))
            {
                start = ParseTimestamp(stamps.TryGetProperty("from", out var f) ? f.GetString() : null);
                end = ParseTimestamp(stamps.TryGetProperty("to", out var e) ? e.GetString() : null);
            }

            segments.Add(new TranscriptSegment
            {
                Start = start,
                End = end,
                Speaker = energy.SpeakerBetween(start, end, echoCoupling),
                Text = text
            });
        }
        return segments;
    }

    /// <summary>
    /// Collapses runs of same-speaker segments into readable paragraphs. Whisper
    /// emits a segment every few seconds, which reads as choppy and lengthens the
    /// prompt for no gain.
    /// </summary>
    private static List<TranscriptSegment> Merge(List<TranscriptSegment> segments)
    {
        var merged = new List<TranscriptSegment>();
        foreach (var segment in segments)
        {
            var last = merged.Count > 0 ? merged[^1] : null;
            if (last is not null && last.Speaker == segment.Speaker
                && segment.Start - last.End < 2.0
                && last.Text.Length + segment.Text.Length < 600)
            {
                last.Text += " " + segment.Text;
                last.End = segment.End;
                continue;
            }
            merged.Add(segment);
        }
        return merged;
    }

    /// <summary>Whisper marks non-speech audio with bracketed tags.</summary>
    private static bool IsNoiseMarker(string text)
    {
        string stripped = text.Trim(' ', '.', '!', '?');
        if (stripped.Length <= 1) return true;
        char first = stripped[0], last = stripped[^1];
        return (first == '[' && last == ']') || (first == '(' && last == ')')
            || (first == '*' && last == '*');
    }

    private static double? ParseProgress(string line)
    {
        if (!line.Contains("progress =")) return null;
        string digits = line[(line.LastIndexOf('=') + 1)..].Trim().TrimEnd('%').Trim();
        return double.TryParse(digits, out double value) ? Math.Clamp(value / 100, 0, 1) : null;
    }

    /// <summary>Parses "HH:MM:SS,mmm".</summary>
    private static double ParseTimestamp(string? value)
    {
        if (value is null) return 0;
        var parts = value.Replace(',', '.').Split(':');
        if (parts.Length != 3) return 0;
        return double.TryParse(parts[0], out double h) && double.TryParse(parts[1], out double m)
            && double.TryParse(parts[2], System.Globalization.CultureInfo.InvariantCulture, out double s)
            ? h * 3600 + m * 60 + s : 0;
    }

    private static string Tail(string text)
    {
        string trimmed = text.Trim();
        return trimmed.Length <= 600 ? trimmed : trimmed[^600..];
    }
}
