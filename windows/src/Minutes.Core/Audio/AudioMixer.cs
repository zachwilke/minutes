namespace Minutes.Core.Audio;

/// <summary>
/// Merges microphone and system audio into a single 16 kHz mono timeline, writes
/// it to disk, and reports levels.
/// </summary>
/// <remarks>
/// Mixing runs a fixed distance behind real time rather than waiting for both
/// sources, which gives each one a grace period to deliver late audio without
/// ever stalling on a source that has gone quiet. Whatever has not arrived by
/// then is genuinely silence.
///
/// Drain is driven by a caller-supplied clock so the whole class is testable
/// without a sound card — the timeline logic is where the bugs live, and it must
/// be verifiable on any machine.
/// </remarks>
public sealed class AudioMixer : IDisposable
{
    private readonly CaptureTimeline _mic = new();
    private readonly CaptureTimeline _system = new();
    private readonly WavWriter? _writer;
    private readonly EnergyTrack _energy = new();
    private readonly int _latencySamples;
    private readonly object _gate = new();

    private float[] _micChunk = new float[AudioConstants.SampleRate];
    private float[] _systemChunk = new float[AudioConstants.SampleRate];
    private float[] _mixed = new float[AudioConstants.SampleRate];

    private long _consumedUpTo;
    private bool _originSet;
    private double _originSeconds;

    public AudioMixer(string? wavPath = null,
                      int latencyMilliseconds = AudioConstants.LatencyMilliseconds)
    {
        _writer = wavPath is null ? null : new WavWriter(wavPath);
        _latencySamples = AudioConstants.SampleRate * latencyMilliseconds / 1000;
    }

    public EnergyTrack Energy => _energy;
    public float PeakMic { get; private set; }
    public float PeakSystem { get; private set; }
    public long MicBuffers => _mic.BuffersReceived;
    public long SystemBuffers => _system.BuffersReceived;
    public long SamplesMixed => _consumedUpTo;
    public TimeSpan Duration => TimeSpan.FromSeconds((double)_consumedUpTo / AudioConstants.SampleRate);

    /// <summary>Raised with each mixed chunk, for live transcription.</summary>
    public event Action<float[], int>? ChunkMixed;

    /// <summary>Raised with each drain's RMS levels, for the meters.</summary>
    public event Action<float, float>? LevelsChanged;

    /// <summary>Accepts resampled 16 kHz mono samples from one source.</summary>
    public void Submit(AudioSourceKind kind, ReadOnlySpan<float> samples, double seconds)
    {
        lock (_gate)
        {
            // The first buffer from either source defines time zero.
            if (!_originSet)
            {
                _originSet = true;
                _originSeconds = seconds;
            }

            long index = (long)Math.Max(0, (seconds - _originSeconds) * AudioConstants.SampleRate);
            var timeline = kind == AudioSourceKind.Microphone ? _mic : _system;
            timeline.Write(samples, index, _consumedUpTo);
        }
    }

    /// <summary>
    /// Mixes everything old enough that late audio has had time to arrive.
    /// </summary>
    /// <param name="nowSeconds">Current capture clock, same basis as Submit.</param>
    /// <param name="flush">Take everything remaining, ignoring the latency window.</param>
    public void Drain(double nowSeconds, bool flush = false)
    {
        float[] mixed;
        int count;
        float micLevel, systemLevel;
        float chunkStart;

        lock (_gate)
        {
            if (!_originSet) return;

            long target = flush
                ? Math.Max(_mic.End, _system.End)
                : (long)((nowSeconds - _originSeconds) * AudioConstants.SampleRate) - _latencySamples;

            count = (int)(target - _consumedUpTo);
            if (count <= 0) return;

            EnsureChunkCapacity(count);
            _mic.Take(target, count, _micChunk);
            _system.Take(target, count, _systemChunk);

            chunkStart = (float)((double)_consumedUpTo / AudioConstants.SampleRate);
            _consumedUpTo = target;

            double micSquared = 0, systemSquared = 0;
            for (int i = 0; i < count; i++)
            {
                float m = _micChunk[i];
                float s = _systemChunk[i];
                micSquared += m * (double)m;
                systemSquared += s * (double)s;
                // Straight sum with a hard clamp: both sources are rarely loud at
                // once, and attenuating would bury the quieter speaker.
                _mixed[i] = Math.Clamp(m + s, -1f, 1f);
            }

            micLevel = (float)Math.Sqrt(micSquared / count);
            systemLevel = (float)Math.Sqrt(systemSquared / count);
            PeakMic = Math.Max(PeakMic, micLevel);
            PeakSystem = Math.Max(PeakSystem, systemLevel);
            _energy.Add(chunkStart, micLevel, systemLevel);
            _writer?.Append(_mixed.AsSpan(0, count));
            mixed = _mixed;
        }

        ChunkMixed?.Invoke(mixed, count);
        LevelsChanged?.Invoke(micLevel, systemLevel);
    }

    private void EnsureChunkCapacity(int count)
    {
        if (count <= _mixed.Length) return;
        int size = _mixed.Length;
        while (size < count) size *= 2;
        _micChunk = new float[size];
        _systemChunk = new float[size];
        _mixed = new float[size];
    }

    public void Dispose() => _writer?.Dispose();
}
