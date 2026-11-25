using System.Runtime.InteropServices;
using Minutes.Core.Audio;

namespace Minutes.Windows.Audio;

/// <summary>
/// Captures from a WASAPI endpoint: the microphone, or — with the loopback flag —
/// whatever the machine is playing.
/// </summary>
/// <remarks>
/// The system-audio side is markedly simpler than the macOS equivalent. Core
/// Audio needed a process tap, an aggregate device and the Audio Recording
/// permission; WASAPI loopback on the default render endpoint needs no permission
/// at all and no device construction.
///
/// Polling rather than event-driven: loopback has a long history of rejecting
/// AUDCLNT_STREAMFLAGS_EVENTCALLBACK, and one code path that works for both
/// endpoints is worth more than a few saved wakeups at a 10 ms poll.
///
/// Timestamps come from the QPC position WASAPI reports per packet, so both
/// sources land on one clock and the mixer can place them on a shared timeline.
///
/// NOT YET RUN AGAINST HARDWARE — see windows/README.md.
/// </remarks>
public sealed class WasapiSource(AudioSourceKind kind) : IAudioSource
{
    private static readonly Guid AudioClientIid = new("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2");
    private static readonly Guid CaptureClientIid = new("C8ADBD64-E71E-48A0-A4DE-185C395CD317");

    private IMMDeviceEnumerator? _enumerator;
    private IAudioClient? _client;
    private IAudioCaptureClient? _capture;
    private string? _deviceId;
    private CancellationTokenSource? _cts;
    private Task? _pump;

    private int _channels;
    private int _bytesPerFrame;
    private bool _isFloat;
    private int _bitsPerSample;

    public AudioSourceKind Kind => kind;

    /// <summary>
    /// Known once the device is open, and can change when it is reopened on a
    /// different endpoint; the session reads it per buffer, so a change is
    /// picked up rather than mis-resampled.
    /// </summary>
    public int SampleRate { get; private set; }
    public event Action<TimestampedSamples>? SamplesAvailable;

    /// <summary>The last problem the capture thread hit and recovered from, if any.</summary>
    public string? LastError { get; private set; }

    private bool Loopback => kind == AudioSourceKind.SystemAudio;

    /// <summary>
    /// Opens synchronously: every step is a blocking COM call. The session runs
    /// this on the thread pool, so the two sources really do open in parallel.
    /// </summary>
    public Task StartAsync(CancellationToken cancellationToken = default)
    {
        var enumeratorClsid = typeof(MMDeviceEnumerator).GUID;
        var enumeratorIid = typeof(IMMDeviceEnumerator).GUID;
        Check(Native.CoCreateInstance(ref enumeratorClsid, IntPtr.Zero, 1, ref enumeratorIid,
                                      out IntPtr enumeratorPtr),
              "could not create the audio device enumerator");
        _enumerator = (IMMDeviceEnumerator)Marshal.GetObjectForIUnknown(enumeratorPtr);
        Marshal.Release(enumeratorPtr);

        Open();

        _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _pump = Task.Factory.StartNew(() => Pump(_cts.Token), _cts.Token,
                                      TaskCreationOptions.LongRunning,
                                      TaskScheduler.Default);
        return Task.CompletedTask;
    }

    /// <summary>Opens the current default endpoint and starts its stream.</summary>
    private void Open()
    {
        // Loopback captures from the *render* endpoint; the microphone is a
        // capture endpoint. That one difference is the whole trick.
        Check(_enumerator!.GetDefaultAudioEndpoint(Loopback ? DataFlow.Render : DataFlow.Capture,
                                                   Role.Multimedia, out IMMDevice device),
              Loopback ? "no audio output device to capture from"
                       : "no microphone is available");
        device.GetId(out string id);
        _deviceId = id;

        var clientIid = AudioClientIid;
        Check(device.Activate(ref clientIid, 1, IntPtr.Zero, out object clientObject),
              "could not open the audio device");
        _client = (IAudioClient)clientObject;
        Marshal.ReleaseComObject(device);

        Check(_client.GetMixFormat(out IntPtr formatPtr), "could not read the device format");
        try
        {
            ReadFormat(formatPtr);

            uint flags = AudClientStreamFlags.AutoConvertPcm | AudClientStreamFlags.SrcDefaultQuality;
            if (Loopback) flags |= AudClientStreamFlags.Loopback;

            // 200 ms of device buffer: enough that a scheduling hiccup does not
            // drop packets, small enough to stay responsive.
            Check(_client.Initialize(AudClientShareMode.Shared, flags,
                                     200 * 10_000L, 0, formatPtr, IntPtr.Zero),
                  "the audio device rejected the capture format");
        }
        finally
        {
            Marshal.FreeCoTaskMem(formatPtr);
        }

        var captureIid = CaptureClientIid;
        Check(_client.GetService(ref captureIid, out object captureObject),
              "could not start reading from the audio device");
        _capture = (IAudioCaptureClient)captureObject;

        Check(_client.Start(), "could not start the audio device");
    }

    private void Close()
    {
        try { _client?.Stop(); } catch { /* device may already be gone */ }
        if (_capture is not null) { Marshal.ReleaseComObject(_capture); _capture = null; }
        if (_client is not null) { Marshal.ReleaseComObject(_client); _client = null; }
    }

    /// <summary>
    /// The default endpoint changes when a headset connects, and an endpoint can
    /// vanish outright. Either way the old stream delivers nothing more — the
    /// far side of the call, or your own voice, would go missing for the rest of
    /// the meeting — so reopen on whatever is default now.
    /// </summary>
    private bool TryReopen(CancellationToken token, string reason)
    {
        LastError = reason;
        Close();
        while (!token.IsCancellationRequested)
        {
            try
            {
                Open();
                return true;
            }
            catch (Exception error)
            {
                // Nothing to open yet — the new device is still arriving, or
                // there is none. Keep trying; the timeline fills the gap.
                LastError = $"{reason}; reopening failed: {error.Message}";
                Close();
                token.WaitHandle.WaitOne(500);
            }
        }
        return false;
    }

    private bool DefaultEndpointChanged()
    {
        if (_enumerator!.GetDefaultAudioEndpoint(Loopback ? DataFlow.Render : DataFlow.Capture,
                                                 Role.Multimedia, out IMMDevice device) < 0)
            return false;   // none right now; the stream's own errors will say so
        device.GetId(out string id);
        Marshal.ReleaseComObject(device);
        return id != _deviceId;
    }

    private void ReadFormat(IntPtr formatPtr)
    {
        var format = Marshal.PtrToStructure<WaveFormatEx>(formatPtr);
        SampleRate = (int)format.SamplesPerSecond;
        _channels = format.Channels;
        _bytesPerFrame = format.BlockAlign;
        _bitsPerSample = format.BitsPerSample;

        // WAVEFORMATEXTENSIBLE hides the real type in its SubFormat GUID; the
        // mix format is almost always 32-bit float, and 32 bits with the
        // extensible tag is safe to treat as float.
        _isFloat = format.FormatTag == WaveFormatEx.FloatTag
                   || (format.FormatTag == WaveFormatEx.ExtensibleTag && _bitsPerSample == 32);

        if (!_isFloat && _bitsPerSample != 16)
            throw new NotSupportedException(
                $"unsupported device format: {_bitsPerSample}-bit, tag {format.FormatTag}");
    }

    private void Pump(CancellationToken token)
    {
        var mono = new float[Math.Max(SampleRate, 48_000)];   // grows if a packet ever exceeds it
        long nextDeviceCheck = Environment.TickCount64 + 2000;

        while (!token.IsCancellationRequested)
        {
            if (Environment.TickCount64 >= nextDeviceCheck)
            {
                nextDeviceCheck = Environment.TickCount64 + 2000;
                if (DefaultEndpointChanged() && !TryReopen(token, "the default device changed"))
                    return;
            }

            int hr = _capture!.GetNextPacketSize(out uint packetFrames);
            if (hr < 0)
            {
                if (!TryReopen(token, DescribeFailure(hr))) return;
                continue;
            }

            if (packetFrames == 0)
            {
                // Nothing waiting. A loopback endpoint reports nothing at all
                // while the machine is silent, which is exactly why buffers are
                // placed by timestamp rather than by arrival.
                Thread.Sleep(10);
                continue;
            }

            while (packetFrames > 0 && !token.IsCancellationRequested)
            {
                hr = _capture.GetBuffer(out IntPtr data, out uint frames, out uint flags,
                                        out _, out ulong qpcPosition);
                if (hr < 0) break;

                if (frames > 0)
                {
                    if (mono.Length < frames) mono = new float[frames];
                    if ((flags & AudClientBufferFlags.Silent) != 0 || data == IntPtr.Zero)
                        Array.Clear(mono, 0, (int)frames);
                    else
                        Downmix(data, (int)frames, mono);

                    // QPC position is in 100-ns units — the same performance
                    // counter the session's clock reads, so drain time and
                    // buffer time share an epoch.
                    double seconds = qpcPosition / 10_000_000.0;
                    SamplesAvailable?.Invoke(new TimestampedSamples(mono, (int)frames, seconds));
                }

                _capture.ReleaseBuffer(frames);
                hr = _capture.GetNextPacketSize(out packetFrames);
                if (hr < 0) break;
            }

            if (hr < 0 && !TryReopen(token, DescribeFailure(hr))) return;
        }
    }

    private static string DescribeFailure(int hr) => hr == Native.AudclntEDeviceInvalidated
        ? "the audio device was disconnected"
        : $"capture failed (HRESULT 0x{hr:X8})";

    /// <summary>Interleaved device audio to mono, by averaging channels.</summary>
    private unsafe void Downmix(IntPtr data, int frames, float[] destination)
    {
        if (_isFloat)
        {
            var source = (float*)data;
            for (int frame = 0; frame < frames; frame++)
            {
                float sum = 0;
                for (int channel = 0; channel < _channels; channel++)
                    sum += source[frame * _channels + channel];
                destination[frame] = sum / _channels;
            }
        }
        else
        {
            var source = (short*)data;
            for (int frame = 0; frame < frames; frame++)
            {
                int sum = 0;
                for (int channel = 0; channel < _channels; channel++)
                    sum += source[frame * _channels + channel];
                destination[frame] = sum / (float)_channels / 32_768f;
            }
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _pump?.Wait(TimeSpan.FromSeconds(2)); } catch { /* shutting down */ }
        try { _client?.Stop(); } catch { /* device may already be gone */ }
    }

    public void Dispose()
    {
        Stop();
        Close();
        if (_enumerator is not null) { Marshal.ReleaseComObject(_enumerator); _enumerator = null; }
        _cts?.Dispose();
    }

    private static void Check(int hr, string message)
    {
        if (hr < 0) throw new InvalidOperationException($"{message} (HRESULT 0x{hr:X8})");
    }
}
