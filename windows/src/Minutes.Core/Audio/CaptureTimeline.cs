namespace Minutes.Core.Audio;

/// <summary>
/// One source's audio, addressed by absolute sample index rather than by arrival
/// order.
/// </summary>
/// <remarks>
/// This is what keeps a bursty system-audio stream aligned with a continuous
/// microphone feed. WASAPI loopback produces nothing at all while the machine is
/// silent, so appending buffers as they arrive squeezes the silences out and
/// drifts the far side of the call earlier and earlier. Placing each buffer at
/// the index its timestamp implies, and filling the gap with real silence, is the
/// fix.
/// </remarks>
public sealed class CaptureTimeline
{
    private readonly int _maxGapSamples;
    private float[] _samples = new float[AudioConstants.SampleRate * 2];
    private int _length;

    public CaptureTimeline(int maxGapSamples = AudioConstants.SampleRate * AudioConstants.MaxGapSeconds)
        => _maxGapSamples = maxGapSamples;

    /// <summary>Absolute index of the first buffered sample.</summary>
    public long Base { get; private set; }

    /// <summary>Absolute index one past the last buffered sample.</summary>
    public long End => Base + _length;

    public bool IsEmpty => _length == 0;
    public long BuffersReceived { get; private set; }
    public long SamplesWritten { get; private set; }

    /// <summary>
    /// Places samples at an absolute index, filling any preceding gap with
    /// silence.
    /// </summary>
    /// <param name="floor">
    /// How far the mixer has already consumed. Audio older than this can no
    /// longer be positioned, so it is appended at the boundary instead of being
    /// dropped — a small timing error beats losing speech.
    /// </param>
    public void Write(ReadOnlySpan<float> incoming, long index, long floor)
    {
        BuffersReceived++;
        if (incoming.Length == 0) return;

        if (_length == 0 && Base < floor) Base = floor;

        long target = Math.Max(index, Base);
        if (target > End)
        {
            // A gap this large means the timestamps are wrong, not that the room
            // fell silent for half a minute.
            long gap = Math.Min(target - End, _maxGapSamples);
            EnsureCapacity(_length + (int)gap + incoming.Length);
            Array.Clear(_samples, _length, (int)gap);
            _length += (int)gap;
        }
        else
        {
            EnsureCapacity(_length + incoming.Length);
        }

        incoming.CopyTo(_samples.AsSpan(_length));
        _length += incoming.Length;
        SamplesWritten += incoming.Length;
    }

    /// <summary>
    /// Consumes samples up to <paramref name="absoluteEnd"/>, writing exactly
    /// <paramref name="count"/> samples into <paramref name="destination"/> and
    /// padding with silence for anything not delivered.
    /// </summary>
    public void Take(long absoluteEnd, int count, Span<float> destination)
    {
        destination[..count].Clear();

        int available = (int)Math.Max(0, Math.Min(absoluteEnd, End) - Base);
        if (available > 0)
        {
            int copy = Math.Min(available, count);
            _samples.AsSpan(0, copy).CopyTo(destination);
            // Shift the remainder down. A few KB per drain; a ring buffer would
            // save little and cost clarity.
            _samples.AsSpan(available, _length - available).CopyTo(_samples.AsSpan(0));
            _length -= available;
            Base += available;
        }

        if (Base < absoluteEnd) Base = absoluteEnd;
    }

    public void Reset()
    {
        Base = 0;
        _length = 0;
        BuffersReceived = 0;
        SamplesWritten = 0;
    }

    private void EnsureCapacity(int needed)
    {
        if (needed <= _samples.Length) return;
        int size = _samples.Length;
        while (size < needed) size *= 2;
        Array.Resize(ref _samples, size);
    }
}
