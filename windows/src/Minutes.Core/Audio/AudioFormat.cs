namespace Minutes.Core.Audio;

/// <summary>The one format everything downstream wants: 16 kHz mono float.</summary>
public static class AudioConstants
{
    /// <summary>Whisper requires 16 kHz; it also keeps an hour under ~115 MB.</summary>
    public const int SampleRate = 16_000;

    /// <summary>
    /// How far behind real time the mixer runs. Long enough to absorb device
    /// jitter and a loopback stream that arrives in bursts, short enough that
    /// live transcription still feels live.
    /// </summary>
    public const int LatencyMilliseconds = 400;

    /// <summary>
    /// A gap longer than this is treated as bad timestamps, not as real silence,
    /// so one wild clock reading cannot allocate an unbounded run of zeros.
    /// </summary>
    public const int MaxGapSeconds = 30;
}

/// <summary>Which side of the conversation a source represents.</summary>
public enum AudioSourceKind
{
    /// <summary>The microphone — the user's own voice.</summary>
    Microphone,

    /// <summary>What the machine is playing — everyone else on the call.</summary>
    SystemAudio
}

/// <summary>
/// A block of captured audio with the timestamp of its first sample.
/// </summary>
/// <remarks>
/// The timestamp is the whole point. A loopback stream only produces buffers
/// while something is playing, so buffers must be placed on a shared timeline by
/// when they happened rather than by when they arrived — otherwise silences get
/// squeezed out and the far side of the call drifts steadily earlier than the
/// microphone. This was the single worst bug in the macOS build; the type carries
/// the timestamp so the mistake is hard to repeat.
/// </remarks>
public readonly struct TimestampedSamples(float[] samples, int count, double seconds)
{
    /// <summary>Buffer holding the samples; may be longer than <see cref="Count"/>.</summary>
    public float[] Samples { get; } = samples;

    /// <summary>Valid sample count within <see cref="Samples"/>.</summary>
    public int Count { get; } = count;

    /// <summary>Seconds from the start of capture to this block's first sample.</summary>
    public double Seconds { get; } = seconds;

    public ReadOnlySpan<float> Span => Samples.AsSpan(0, Count);
}
