namespace Minutes.Core.Audio;

/// <summary>
/// A source that fabricates audio on a schedule, for tests and for exercising
/// the capture session on a machine with no WASAPI.
/// </summary>
/// <remarks>
/// It can imitate the two behaviours that matter: a microphone that delivers
/// continuously, and a loopback stream that delivers only in bursts and takes a
/// while to open.
/// </remarks>
public sealed class SyntheticAudioSource(
    AudioSourceKind kind,
    int sampleRate = 48_000,
    double startupSeconds = 0,
    double amplitude = 0.3,
    double frequency = 440,
    bool bursty = false) : IAudioSource
{
    private CancellationTokenSource? _cts;
    private Task? _pump;
    private long _sampleCursor;

    public AudioSourceKind Kind => kind;
    public int SampleRate => sampleRate;
    public event Action<TimestampedSamples>? SamplesAvailable;

    /// <summary>Capture-clock seconds; overridable so tests can drive time.</summary>
    public Func<double> Clock { get; init; } = () => CaptureClock.Now;

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (startupSeconds > 0)
            await Task.Delay(TimeSpan.FromSeconds(startupSeconds), cancellationToken);

        _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = _cts.Token;
        double start = Clock();

        _pump = Task.Run(async () =>
        {
            int blockSamples = sampleRate / 10;   // 100 ms blocks
            var buffer = new float[blockSamples];
            int block = 0;
            while (!token.IsCancellationRequested)
            {
                // A bursty source stays silent most of the time, like loopback
                // when nothing is playing: it emits nothing at all rather than
                // emitting zeros.
                bool emit = !bursty || block % 10 == 0;
                if (emit)
                {
                    for (int i = 0; i < blockSamples; i++)
                    {
                        double t = (_sampleCursor + i) / (double)sampleRate;
                        buffer[i] = (float)(amplitude * Math.Sin(2 * Math.PI * frequency * t));
                    }
                    double seconds = start + block * 0.1;
                    SamplesAvailable?.Invoke(new TimestampedSamples(buffer, blockSamples, seconds));
                }
                _sampleCursor += blockSamples;
                block++;
                try { await Task.Delay(100, token); } catch (OperationCanceledException) { break; }
            }
        }, token);
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _pump?.Wait(TimeSpan.FromSeconds(1)); } catch { /* shutting down */ }
    }

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
    }
}
