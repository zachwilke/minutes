namespace Minutes.Core.Audio;

/// <summary>
/// One capture source, at its own native sample rate.
/// </summary>
/// <remarks>
/// An interface rather than a concrete WASAPI class so the capture session — the
/// part with the interesting logic — can be exercised without a sound card. The
/// Windows implementations sit behind this; a synthetic source stands in for
/// tests.
/// </remarks>
public interface IAudioSource : IDisposable
{
    AudioSourceKind Kind { get; }

    /// <summary>Native rate; the session resamples to 16 kHz.</summary>
    int SampleRate { get; }

    /// <summary>
    /// Mono float samples with the capture-clock time of the first sample.
    /// Raised on a background thread.
    /// </summary>
    event Action<TimestampedSamples>? SamplesAvailable;

    /// <summary>Opens the device. Completes once samples can flow.</summary>
    Task StartAsync(CancellationToken cancellationToken = default);

    void Stop();
}
