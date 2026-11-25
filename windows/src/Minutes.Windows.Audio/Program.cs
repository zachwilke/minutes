using Minutes.Core;
using Minutes.Core.Audio;
using Minutes.Core.Meetings;
using Minutes.Core.Pipeline;
using Minutes.Core.Prompts;

namespace Minutes.Windows.Audio;

/// <summary>
/// The headless capture harness — the Windows counterpart of the macOS
/// diagnostics, and the acceptance test for this phase.
/// </summary>
internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Contains("--test-capture"))
            return await TestCapture(ParseSeconds(args, "--test-capture", 4), args.Contains("--synthetic"));
        if (args.Contains("--time-start"))
            return await TimeStart(args.Contains("--synthetic"));
        if (args.Contains("--selftest"))
            return await Selftest(ValueAfter(args, "--selftest"));
        if (args.Contains("--doctor"))
            return await Doctor();

        Console.WriteLine("""
            Minutes capture harness

              --test-capture [seconds]   record briefly and report what each source delivered
              --time-start               measure how long until the first source is capturing
              --synthetic                use fabricated sources instead of real devices
              --selftest <file.wav>      transcribe a wav and summarise it
              --doctor                   check tools, model and Claude sign-in
            """);
        return 0;
    }

    private static IAudioSource[] BuildSources(bool synthetic) => synthetic
        ? [new SyntheticAudioSource(AudioSourceKind.Microphone),
           new SyntheticAudioSource(AudioSourceKind.SystemAudio, startupSeconds: 0.1, bursty: true)]
        : [new WasapiSource(AudioSourceKind.Microphone),
           new WasapiSource(AudioSourceKind.SystemAudio)];

    private static async Task<int> TestCapture(double seconds, bool synthetic)
    {
        string path = Path.Combine(Path.GetTempPath(), "minutes-capture-test.wav");
        Console.WriteLine($"Recording {seconds:F0}s to verify audio capture…");

        using var session = new CaptureSession(BuildSources(synthetic), path);
        try
        {
            await session.StartAsync();
        }
        catch (Exception error)
        {
            Console.WriteLine($"CAPTURE FAILED: {error.Message}");
            return 1;
        }

        session.StartPump();
        await Task.Delay(TimeSpan.FromSeconds(seconds));
        var result = session.Stop();

        Console.WriteLine();
        Console.WriteLine($"Microphone captured  : {(result.CapturedMicrophone ? "yes" : "no")}");
        Console.WriteLine($"System audio captured: {(result.CapturedSystemAudio ? "yes" : "no")}");
        if (result.DegradedReason is not null) Console.WriteLine($"Note: {result.DegradedReason}");
        Console.WriteLine($"Duration written     : {result.Duration.TotalSeconds:F2}s");
        Console.WriteLine($"Peak mic level       : {result.PeakMicrophone:F4}");
        Console.WriteLine($"Peak system level    : {result.PeakSystemAudio:F4}");
        Console.WriteLine($"Buffers from mic     : {result.MicrophoneBuffers}");
        Console.WriteLine($"Buffers from system  : {result.SystemAudioBuffers}");
        Console.WriteLine($"Energy frames        : {session.Energy.Count}");
        Console.WriteLine($"File                 : {path}");
        Console.WriteLine();

        // The same acceptance bar the macOS harness uses.
        if (result.Duration.TotalSeconds < seconds * 0.5)
        {
            Console.WriteLine("WARNING: far less audio was written than expected.");
            return 1;
        }
        Console.WriteLine("CAPTURE TEST PASSED");
        return 0;
    }

    private static async Task<int> TimeStart(bool synthetic)
    {
        // Twice: the first start of a session pays device spin-up the second
        // does not.
        for (int attempt = 1; attempt <= 2; attempt++)
        {
            using var session = new CaptureSession(BuildSources(synthetic));
            try
            {
                await session.StartAsync();
            }
            catch (Exception error)
            {
                Console.WriteLine($"start #{attempt} FAILED: {error.Message}");
                continue;
            }
            long ms = session.TimeToFirstSourceMilliseconds;
            await Task.Delay(300);
            session.Stop();
            Console.WriteLine($"start #{attempt}: {ms}ms to first source capturing "
                              + "(others attach behind it)");
            if (ms > 150)
                Console.WriteLine("    over the 150ms budget — see windows/PLAN.md");
        }
        return 0;
    }

    private static async Task<int> Doctor()
    {
        Console.WriteLine("Minutes environment check");
        Console.WriteLine("---------------------------");
        Console.WriteLine($"Support folder : {AppPaths.SupportRoot}");
        Console.WriteLine($"whisper-cli    : {ProcessRunner.Locate("whisper-cli") ?? "NOT FOUND"}");
        Console.WriteLine($"claude         : {ProcessRunner.Locate("claude") ?? "NOT FOUND"}");

        string? model = WhisperTranscriber.FindModel();
        Console.WriteLine(model is null
            ? "Whisper model  : NOT FOUND"
            : $"Whisper model  : {Path.GetFileName(model)} ({new FileInfo(model).Length / 1_000_000} MB)");

        Console.WriteLine($"Meetings stored: {MeetingLibrary.LoadAll().Count}");

        try
        {
            var status = await new ClaudeRunner().GetAuthStatusAsync();
            Console.WriteLine(status is null ? "Claude         : could not read auth status"
                : status.LoggedIn
                    ? $"Claude         : signed in ({string.Join(" · ", new[] {
                        status.Account.Email, status.Account.Organization,
                        status.Account.Subscription, status.Account.AuthMethod }
                        .Where(x => x is not null))})"
                    : "Claude         : SIGNED OUT — run `claude auth login`");
        }
        catch (Exception error)
        {
            Console.WriteLine($"Claude         : check failed — {error.Message}");
        }
        return 0;
    }

    /// <summary>
    /// Runs a wav through the whole pipeline. The phase-2 acceptance test.
    /// </summary>
    private static async Task<int> Selftest(string? audioPath)
    {
        if (audioPath is null || !File.Exists(audioPath))
        {
            Console.WriteLine("usage: --selftest <file.wav>");
            return 1;
        }

        await Doctor();
        Console.WriteLine();
        Console.WriteLine($"Transcribing {Path.GetFileName(audioPath)} with Whisper…");

        // No energy track for a bare wav, so segments come back unattributed —
        // the same behaviour as the macOS selftest.
        var energy = new EnergyTrack();
        var transcriber = new WhisperTranscriber
        {
            OnProgress = value =>
            {
                if ((int)(value * 100) % 25 == 0) Console.WriteLine($"  {(int)(value * 100)}%");
            }
        };

        List<TranscriptSegment> segments;
        try
        {
            segments = await transcriber.TranscribeAsync(audioPath, energy);
        }
        catch (Exception error)
        {
            Console.WriteLine($"TRANSCRIPTION FAILED: {error.Message}");
            return 1;
        }

        Console.WriteLine();
        Console.WriteLine($"Transcript ({segments.Count} segments)");
        Console.WriteLine("---------------------------");
        foreach (var segment in segments)
            Console.WriteLine($"[{segment.TimestampLabel}] {segment.SpeakerLabel}: {segment.Text}");

        var meeting = new Meeting
        {
            Title = "Selftest meeting",
            StartedAt = DateTimeOffset.UtcNow,
            EndedAt = DateTimeOffset.UtcNow.AddSeconds(segments.Count > 0 ? segments[^1].End : 60),
            Segments = segments,
            Notes = "- checking that the pipeline works end to end"
        };

        Console.WriteLine();
        Console.WriteLine("Summarizing with Claude…");
        try
        {
            string summary = await new ClaudeRunner().SummarizeAsync(meeting, SummaryTemplate.General);
            Console.WriteLine();
            Console.WriteLine("Summary");
            Console.WriteLine("---------------------------");
            Console.WriteLine(summary);
            Console.WriteLine();
            Console.WriteLine("SELFTEST PASSED");
            return 0;
        }
        catch (Exception error)
        {
            Console.WriteLine($"SUMMARIZATION FAILED: {error.Message}");
            return 1;
        }
    }

    private static string? ValueAfter(string[] args, string flag)
    {
        int index = Array.IndexOf(args, flag);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static double ParseSeconds(string[] args, string flag, double fallback)
    {
        int index = Array.IndexOf(args, flag);
        return index >= 0 && index + 1 < args.Length && double.TryParse(args[index + 1], out double value)
            ? value : fallback;
    }
}
