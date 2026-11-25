namespace Minutes.Core.Audio;

/// <summary>
/// Streaming 16-bit PCM WAV writer, 16 kHz mono.
/// </summary>
/// <remarks>
/// The RIFF sizes are rewritten every few seconds while recording. A WAV whose
/// header still says zero length is unreadable, so if the process is killed the
/// file on disk should already be valid — on macOS a force-quit left 265 KB of
/// real audio behind a zero-length header, and the samples were only recoverable
/// because the header could be repaired afterwards. Both halves of that lesson
/// are here.
/// </remarks>
public sealed class WavWriter : IDisposable
{
    private const int HeaderBytes = 44;
    private const int Channels = 1;
    private const int BitsPerSample = 16;
    private const int BlockAlign = Channels * BitsPerSample / 8;

    private static readonly int HeaderRefreshFrames = AudioConstants.SampleRate * 5;

    private readonly FileStream _stream;
    private readonly byte[] _scratch = new byte[8192];
    private long _framesWritten;
    private long _framesAtLastRefresh;

    public WavWriter(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? ".");
        _stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        _stream.Write(BuildHeader(0));
    }

    public TimeSpan Duration => TimeSpan.FromSeconds((double)_framesWritten / AudioConstants.SampleRate);

    /// <summary>Appends float samples in [-1, 1], clamped and converted to Int16.</summary>
    public void Append(ReadOnlySpan<float> samples)
    {
        if (samples.Length == 0) return;

        int offset = 0;
        while (offset < samples.Length)
        {
            int chunk = Math.Min((samples.Length - offset), _scratch.Length / 2);
            for (int i = 0; i < chunk; i++)
            {
                float clamped = Math.Clamp(samples[offset + i], -1f, 1f);
                short value = (short)(clamped * 32_767f);
                _scratch[i * 2] = (byte)(value & 0xFF);
                _scratch[i * 2 + 1] = (byte)((value >> 8) & 0xFF);
            }
            _stream.Write(_scratch, 0, chunk * 2);
            offset += chunk;
        }

        _framesWritten += samples.Length;
        if (_framesWritten - _framesAtLastRefresh >= HeaderRefreshFrames) RefreshHeader();
    }

    /// <summary>Rewrites the sizes, then returns to the end to keep appending.</summary>
    private void RefreshHeader()
    {
        long position = _stream.Position;
        _stream.Position = 0;
        _stream.Write(BuildHeader(_framesWritten));
        _stream.Position = position;
        _framesAtLastRefresh = _framesWritten;
    }

    public void Dispose()
    {
        if (!_stream.CanWrite) return;
        RefreshHeader();
        _stream.Flush();
        _stream.Dispose();
    }

    private static byte[] BuildHeader(long frames)
    {
        long dataBytes = frames * BlockAlign;
        var header = new byte[HeaderBytes];
        var span = header.AsSpan();

        "RIFF"u8.CopyTo(span);
        WriteUInt32(span[4..], (uint)(36 + dataBytes));
        "WAVE"u8.CopyTo(span[8..]);
        "fmt "u8.CopyTo(span[12..]);
        WriteUInt32(span[16..], 16);
        WriteUInt16(span[20..], 1);                                   // PCM
        WriteUInt16(span[22..], Channels);
        WriteUInt32(span[24..], AudioConstants.SampleRate);
        WriteUInt32(span[28..], AudioConstants.SampleRate * BlockAlign);
        WriteUInt16(span[32..], BlockAlign);
        WriteUInt16(span[34..], BitsPerSample);
        "data"u8.CopyTo(span[36..]);
        WriteUInt32(span[40..], (uint)dataBytes);
        return header;
    }

    private static void WriteUInt32(Span<byte> target, uint value)
    {
        target[0] = (byte)value; target[1] = (byte)(value >> 8);
        target[2] = (byte)(value >> 16); target[3] = (byte)(value >> 24);
    }

    private static void WriteUInt16(Span<byte> target, int value)
    {
        target[0] = (byte)value; target[1] = (byte)(value >> 8);
    }

    /// <summary>
    /// Repairs a file abandoned mid-recording, whose header still claims zero
    /// length, by deriving the real frame count from the file size. Returns the
    /// recovered duration, or null if there is nothing to recover.
    /// </summary>
    public static TimeSpan? RepairHeaderIfNeeded(string path)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length <= HeaderBytes) return null;

        long frames = (info.Length - HeaderBytes) / BlockAlign;
        if (frames <= 0) return null;

        using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite);
        var existing = new byte[HeaderBytes];
        if (stream.Read(existing, 0, HeaderBytes) == HeaderBytes)
        {
            uint declared = (uint)(existing[40] | (existing[41] << 8)
                                 | (existing[42] << 16) | (existing[43] << 24));
            if (declared == frames * BlockAlign)
                return TimeSpan.FromSeconds((double)frames / AudioConstants.SampleRate);
        }

        stream.Position = 0;
        stream.Write(BuildHeader(frames));
        return TimeSpan.FromSeconds((double)frames / AudioConstants.SampleRate);
    }
}
