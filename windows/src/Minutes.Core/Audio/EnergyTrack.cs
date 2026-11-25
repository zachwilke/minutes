namespace Minutes.Core.Audio;

/// <summary>Who was speaking during a transcript segment.</summary>
public enum Speaker { Me, Others, Unknown }

/// <summary>
/// Per-chunk loudness of each source, used to label transcript segments without
/// running a diarization model: if the microphone was much louder than the
/// system output over a segment, the user was talking.
/// </summary>
/// <remarks>
/// Binary layout is shared with the macOS app (flat little-endian Float32
/// triples: time, mic, system) so a library written on either platform reads on
/// the other. See shared/spec/meeting-format.md.
/// </remarks>
public sealed class EnergyTrack
{
    public readonly record struct Frame(float Time, float Mic, float System);

    private readonly List<Frame> _frames = [];

    public IReadOnlyList<Frame> Frames => _frames;
    public int Count => _frames.Count;

    public void Add(float time, float mic, float system) => _frames.Add(new Frame(time, mic, system));

    /// <summary>
    /// Decides who was talking across a time range. Requires a clear margin
    /// between the sources, otherwise reports Unknown rather than inventing an
    /// attribution.
    /// </summary>
    /// <remarks>
    /// Binary search rather than a scan: this runs once per transcript segment,
    /// and a two-hour meeting holds ~72k frames, so filtering the whole list per
    /// segment made labelling quadratic.
    /// </remarks>
    /// <summary>
    /// How strongly the call's audio leaks into the microphone (speakers, no
    /// echo cancellation): the lower quartile of mic/system level where the
    /// call is clearly audible; 0 below 0.1. Mirrors macOS EnergyTrack.
    /// </summary>
    public float EchoCoupling()
    {
        var ratios = _frames.Where(f => f.System > 0.01f).Select(f => f.Mic / f.System).ToList();
        if (ratios.Count < 50) return 0;
        ratios.Sort();
        float quartile = Math.Min(ratios[ratios.Count / 4], 1.5f);
        return quartile < 0.1f ? 0 : quartile;
    }

    /// <param name="echoCoupling">From <see cref="EchoCoupling"/>, computed once
    /// per recording; removed from the mic before comparing.</param>
    public Speaker SpeakerBetween(double startSeconds, double endSeconds, float echoCoupling = 0)
    {
        float lower = (float)(startSeconds - 0.15);
        float upper = (float)(endSeconds + 0.15);

        int lo = 0, hi = _frames.Count;
        while (lo < hi)
        {
            int mid = (lo + hi) / 2;
            if (_frames[mid].Time < lower) lo = mid + 1; else hi = mid;
        }

        double micEnergy = 0, systemEnergy = 0;
        bool any = false;
        for (int i = lo; i < _frames.Count && _frames[i].Time <= upper; i++)
        {
            double mic = Math.Max(0, _frames[i].Mic - echoCoupling * (double)_frames[i].System);
            micEnergy += mic * mic;
            systemEnergy += _frames[i].System * (double)_frames[i].System;
            any = true;
        }

        if (!any) return Speaker.Unknown;
        double total = micEnergy + systemEnergy;
        if (total <= 1e-7) return Speaker.Unknown;

        double micShare = micEnergy / total;
        if (micShare > 0.62) return Speaker.Me;
        if (micShare < 0.38) return Speaker.Others;
        return Speaker.Unknown;
    }

    public void Write(string path)
    {
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write);
        Span<byte> buffer = stackalloc byte[12];
        foreach (var frame in _frames)
        {
            BitConverter.TryWriteBytes(buffer[..4], frame.Time);
            BitConverter.TryWriteBytes(buffer[4..8], frame.Mic);
            BitConverter.TryWriteBytes(buffer[8..], frame.System);
            stream.Write(buffer);
        }
    }

    public static EnergyTrack Read(string path)
    {
        var track = new EnergyTrack();
        if (!File.Exists(path)) return track;

        var bytes = File.ReadAllBytes(path);
        for (int offset = 0; offset + 12 <= bytes.Length; offset += 12)
        {
            track._frames.Add(new Frame(
                BitConverter.ToSingle(bytes, offset),
                BitConverter.ToSingle(bytes, offset + 4),
                BitConverter.ToSingle(bytes, offset + 8)));
        }
        return track;
    }
}
