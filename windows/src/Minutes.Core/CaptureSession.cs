using Minutes.Core.Audio;

namespace Minutes.Core;

/// <summary>What a finished capture produced.</summary>
public sealed record CaptureResult(
    TimeSpan Duration,
    bool CapturedMicrophone,
    bool CapturedSystemAudio,
    long MicrophoneBuffers,
    long SystemAudioBuffers,
    float PeakMicrophone,
    float PeakSystemAudio,
    string? DegradedReason);

/// <summary>
/// Drives capture: opens the sources, resamples each to 16 kHz, feeds the mixer,
/// and pumps the drain.
/// </summary>
/// <remarks>
/// Two behaviours are carried over from macOS deliberately.
///
/// Sources start in parallel, and <see cref="StartAsync"/> returns as soon as the
/// <em>first</em> one is capturing rather than the last. A microphone can take
/// half a second of hardware spin-up while a loopback stream opens in ~100 ms;
/// since every buffer is placed by timestamp, audio flows from the moment the
/// fastest source is live and the slower one attaches behind it. Waiting bought
/// nothing but lag between clicking record and recording.
///
/// A source that opens after <see cref="Stop"/> shuts itself down rather than
/// leaving a live device behind.
/// </remarks>
public sealed class CaptureSession : IDisposable
{
    private readonly List<IAudioSource> _sources;
    /// <summary>
    /// Per-source state, created once in the constructor and only ever touched
    /// by that source's capture thread (under its own lock) — the dictionary
    /// itself is never written after construction.
    /// </summary>
    private sealed class Lane
    {
        public readonly List<float> Scratch = new(AudioConstants.SampleRate);
        public WindowedSincResampler? Resampler;
    }

    private readonly Dictionary<AudioSourceKind, Lane> _lanes = [];
    private readonly AudioMixer _mixer;
    private readonly Func<double> _clock;
    private readonly object _gate = new();
    private readonly List<Exception> _failures = [];

    private readonly HashSet<AudioSourceKind> _live = [];
    private bool _stopped;
    private Timer? _pumpTimer;

    public CaptureSession(IEnumerable<IAudioSource> sources,
                          string? wavPath = null,
                          Func<double>? clock = null,
                          int latencyMilliseconds = AudioConstants.LatencyMilliseconds)
    {
        _sources = [.. sources];
        // The clock WASAPI's QPC buffer positions are on. TickCount64 has a
        // different epoch and ~15 ms resolution, so drain time and buffer time
        // drifted apart — exactly the arrival-order error the timeline exists
        // to prevent.
        _clock = clock ?? (() => CaptureClock.Now);
        _mixer = new AudioMixer(wavPath, latencyMilliseconds);

        foreach (var source in _sources)
        {
            _lanes[source.Kind] = new Lane();
            source.SamplesAvailable += block => Ingest(source, block);
        }
    }

    public AudioMixer Mixer => _mixer;
    public EnergyTrack Energy => _mixer.Energy;

    /// <summary>Milliseconds from the call to the first source capturing.</summary>
    public long TimeToFirstSourceMilliseconds { get; private set; }

    /// <summary>
    /// Opens every source concurrently; completes when the first is live, or when
    /// all have failed.
    /// </summary>
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        var started = System.Diagnostics.Stopwatch.StartNew();
        var firstLive = new TaskCompletionSource();

        var attempts = _sources.Select(async source =>
        {
            try
            {
                // On the pool: a real device opens with blocking COM calls and
                // returns an already-completed task, so awaiting it directly ran
                // the sources one after the other.
                await Task.Run(() => source.StartAsync(cancellationToken), cancellationToken);
                bool orphaned;
                lock (_gate)
                {
                    _live.Add(source.Kind);
                    orphaned = _stopped;
                }
                if (orphaned) { source.Stop(); return; }   // opened after Stop
                firstLive.TrySetResult();
            }
            catch (Exception error)
            {
                lock (_gate) _failures.Add(error);
            }
        }).ToArray();

        var all = Task.WhenAll(attempts);
        await Task.WhenAny(firstLive.Task, all);

        lock (_gate)
        {
            if (_live.Count == 0)
            {
                var reason = _failures.Count > 0
                    ? string.Join(" ", _failures.Select(f => f.Message))
                    : "No audio sources could be opened.";
                throw new InvalidOperationException(reason);
            }
        }

        TimeToFirstSourceMilliseconds = started.ElapsedMilliseconds;
    }

    /// <summary>Starts the periodic drain. Tests call <see cref="Pump"/> instead.</summary>
    public void StartPump(int intervalMilliseconds = 100)
        => _pumpTimer = new Timer(_ => Pump(), null, intervalMilliseconds, intervalMilliseconds);

    /// <summary>Mixes whatever is now old enough.</summary>
    public void Pump() => _mixer.Drain(_clock());

    public CaptureResult Stop()
    {
        lock (_gate) _stopped = true;
        _pumpTimer?.Dispose();
        _pumpTimer = null;
        foreach (var source in _sources) source.Stop();

        // Flush so the last words are not clipped.
        _mixer.Drain(_clock(), flush: true);

        bool wantedMic = _sources.Any(s => s.Kind == AudioSourceKind.Microphone);
        bool wantedSystem = _sources.Any(s => s.Kind == AudioSourceKind.SystemAudio);
        bool gotMic = _live.Contains(AudioSourceKind.Microphone);
        bool gotSystem = _live.Contains(AudioSourceKind.SystemAudio);

        string? degraded = null;
        if (wantedSystem && !gotSystem)
            degraded = _failures.FirstOrDefault()?.Message
                ?? "System audio was unavailable; recorded microphone only.";
        else if (wantedMic && !gotMic)
            degraded = _failures.FirstOrDefault()?.Message
                ?? "Microphone was unavailable; recorded system audio only.";

        return new CaptureResult(_mixer.Duration, gotMic, gotSystem,
                                 _mixer.MicBuffers, _mixer.SystemBuffers,
                                 _mixer.PeakMic, _mixer.PeakSystem, degraded);
    }

    private void Ingest(IAudioSource source, TimestampedSamples block)
    {
        var kind = source.Kind;
        var lane = _lanes[kind];
        var scratch = lane.Scratch;
        lock (lane)
        {
            // Built from the first buffer, not in the constructor: a device's
            // rate is only known once it is open. Rebuilt if a reopened device
            // runs at a different rate.
            int rate = source.SampleRate;
            if (rate <= 0) return;
            if (lane.Resampler is null || lane.Resampler.InputRate != rate)
                lane.Resampler = new WindowedSincResampler(rate);
            scratch.Clear();
            lane.Resampler.Resample(block.Span, scratch);
            if (scratch.Count == 0) return;
            // CollectionsMarshal would avoid the copy, but a span over a List is
            // not safe to hand across a lock boundary; the copy is a few KB.
            _mixer.Submit(kind, scratch.ToArray(), block.Seconds);
        }
    }

    public void Dispose()
    {
        _pumpTimer?.Dispose();
        foreach (var source in _sources) source.Dispose();
        _mixer.Dispose();
    }
}
