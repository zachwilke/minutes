using Minutes.Core;

namespace Minutes.Core.Tests;

/// <summary>
/// Exercises the capture session with synthetic sources — no sound card, so
/// these run anywhere, which is the point: the startup-gating and degradation
/// rules are logic, and logic should not need hardware to verify.
/// </summary>
public class CaptureSessionTests
{
    [Fact]
    public async Task ReturnsAsSoonAsTheFastestSourceIsLive()
    {
        // Mirrors real hardware: loopback opens quickly, the microphone does not.
        var fast = new SyntheticAudioSource(AudioSourceKind.SystemAudio, startupSeconds: 0.05);
        var slow = new SyntheticAudioSource(AudioSourceKind.Microphone, startupSeconds: 0.60);

        using var session = new CaptureSession([fast, slow]);
        await session.StartAsync();

        // Must not have waited for the microphone; sequential startup would have
        // been ~650 ms, and waiting for both ~600 ms.
        Assert.InRange(session.TimeToFirstSourceMilliseconds, 0, 300);
        session.Stop();
    }

    [Fact]
    public async Task SlowSourceStillContributesAfterStartReturns()
    {
        var fast = new SyntheticAudioSource(AudioSourceKind.SystemAudio, startupSeconds: 0.02);
        var slow = new SyntheticAudioSource(AudioSourceKind.Microphone, startupSeconds: 0.35);

        using var session = new CaptureSession([fast, slow], latencyMilliseconds: 0);
        await session.StartAsync();

        // Let the late source attach and both deliver for a while.
        for (int i = 0; i < 12; i++) { await Task.Delay(100); session.Pump(); }
        var result = session.Stop();

        Assert.True(result.CapturedSystemAudio, "fast source should be live");
        Assert.True(result.CapturedMicrophone, "late source should have attached");
        Assert.True(result.MicrophoneBuffers > 0, "late source should have delivered audio");
        Assert.True(result.PeakMicrophone > 0.05f, "late source audio should reach the mix");
        Assert.Null(result.DegradedReason);
    }

    [Fact]
    public async Task ReportsDegradedWhenOneSourceFails()
    {
        var working = new SyntheticAudioSource(AudioSourceKind.Microphone);
        var broken = new FailingSource(AudioSourceKind.SystemAudio);

        using var session = new CaptureSession([working, broken], latencyMilliseconds: 0);
        await session.StartAsync();          // must not throw: one source is fine
        await Task.Delay(250);
        session.Pump();
        var result = session.Stop();

        Assert.True(result.CapturedMicrophone);
        Assert.False(result.CapturedSystemAudio);
        Assert.NotNull(result.DegradedReason);
        Assert.Contains("no loopback device", result.DegradedReason);
    }

    [Fact]
    public async Task ThrowsOnlyWhenEverySourceFails()
    {
        using var session = new CaptureSession(
            [new FailingSource(AudioSourceKind.Microphone),
             new FailingSource(AudioSourceKind.SystemAudio)]);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => session.StartAsync());
        Assert.Contains("no loopback device", error.Message);
    }

    [Fact]
    public async Task BurstySourceDoesNotCollapseTheTimeline()
    {
        // The loopback failure mode, end to end through the session: a source
        // that only speaks 10% of the time must not compress the recording.
        var mic = new SyntheticAudioSource(AudioSourceKind.Microphone);
        var loopback = new SyntheticAudioSource(AudioSourceKind.SystemAudio, bursty: true);

        using var session = new CaptureSession([mic, loopback], latencyMilliseconds: 0);
        await session.StartAsync();
        for (int i = 0; i < 20; i++) { await Task.Delay(100); session.Pump(); }
        var result = session.Stop();

        // ~2 s of wall clock in, ~2 s of audio out.
        Assert.InRange(result.Duration.TotalSeconds, 1.5, 2.6);
        Assert.True(result.SystemAudioBuffers > 0);
        Assert.True(result.MicrophoneBuffers > result.SystemAudioBuffers,
                    "the continuous source should deliver more buffers than the bursty one");
    }

    [Fact]
    public async Task WritesAReadableWavFile()
    {
        string path = Path.Combine(Path.GetTempPath(), $"session-{Guid.NewGuid():N}.wav");
        try
        {
            var mic = new SyntheticAudioSource(AudioSourceKind.Microphone);
            using (var session = new CaptureSession([mic], path, latencyMilliseconds: 0))
            {
                await session.StartAsync();
                for (int i = 0; i < 8; i++) { await Task.Delay(100); session.Pump(); }
                session.Stop();
            }

            var header = new byte[44];
            using var stream = File.OpenRead(path);
            Assert.Equal(44, stream.Read(header, 0, 44));
            Assert.Equal("RIFF"u8.ToArray(), header[..4]);
            Assert.Equal("WAVE"u8.ToArray(), header[8..12]);

            uint dataBytes = BitConverter.ToUInt32(header, 40);
            Assert.True(dataBytes > 0, "the header must declare its real length, not zero");
            Assert.Equal(stream.Length - 44, dataBytes);
        }
        finally { File.Delete(path); }
    }

    /// <summary>Stands in for a machine with no usable device.</summary>
    private sealed class FailingSource(AudioSourceKind kind) : IAudioSource
    {
        public AudioSourceKind Kind => kind;
        public int SampleRate => 48_000;
        public event Action<TimestampedSamples>? SamplesAvailable;

        public Task StartAsync(CancellationToken cancellationToken = default)
        {
            _ = SamplesAvailable;   // silence the unused-event warning
            throw new InvalidOperationException("no loopback device is available");
        }

        public void Stop() { }
        public void Dispose() { }
    }
}
