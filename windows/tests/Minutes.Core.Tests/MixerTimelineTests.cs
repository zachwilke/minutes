namespace Minutes.Core.Tests;

/// <summary>
/// The timeline is where the macOS build's worst bug lived: a system-audio
/// stream that only produces buffers while something is playing, appended in
/// arrival order, silently squeezes out the silences and drifts the far side of
/// the call earlier and earlier. These tests encode that failure so the Windows
/// port cannot repeat it.
/// </summary>
public class MixerTimelineTests
{
    private static float[] Constant(float value, int count)
    {
        var samples = new float[count];
        samples.AsSpan().Fill(value);
        return samples;
    }

    private const int Rate = AudioConstants.SampleRate;

    /// <summary>Everything the mixer emits, in order, so tests can check where
    /// audio landed — not just how much of it there is.</summary>
    private static List<float> Record(AudioMixer mixer)
    {
        var all = new List<float>();
        mixer.ChunkMixed += (buffer, count) => all.AddRange(buffer.AsSpan(0, count).ToArray());
        return all;
    }

    private static float At(List<float> mix, double seconds) => mix[(int)(seconds * Rate)];

    [Fact]
    public void GapsBecomeSilenceRatherThanBeingSqueezedOut()
    {
        using var mixer = new AudioMixer(latencyMilliseconds: 0);
        var mix = Record(mixer);

        // Microphone runs continuously for three seconds.
        for (int block = 0; block < 30; block++)
            mixer.Submit(AudioSourceKind.Microphone, Constant(0.1f, Rate / 10), block * 0.1);

        // System audio speaks only in the first 0.2s, then goes quiet — exactly
        // what loopback does — and speaks again at 2.5s.
        mixer.Submit(AudioSourceKind.SystemAudio, Constant(0.5f, Rate / 5), 0.0);
        mixer.Submit(AudioSourceKind.SystemAudio, Constant(0.5f, Rate / 5), 2.5);

        mixer.Drain(3.0);

        // Three seconds of wall clock must yield three seconds of audio: the
        // silence is real content, not something to compress away.
        Assert.InRange(mixer.Duration.TotalSeconds, 2.95, 3.05);
        // And the second burst sits at 2.5 s. Arrival order would have put it
        // straight after the first, at 0.2 s — with the duration unchanged,
        // which is why duration alone proves nothing.
        Assert.Equal(0.6f, At(mix, 2.6), 3);
        Assert.Equal(0.1f, At(mix, 0.3), 3);
        Assert.Equal(0.1f, At(mix, 1.5), 3);
    }

    [Fact]
    public void LateSystemAudioLandsAtItsOwnTimestampNotAtTheEnd()
    {
        using var mixer = new AudioMixer(latencyMilliseconds: 0);
        var chunks = new List<(float start, float[] samples, int count)>();
        long consumed = 0;
        mixer.ChunkMixed += (buffer, count) =>
        {
            float start = (float)((double)consumed / Rate);
            chunks.Add((start, buffer[..count].ToArray(), count));
            consumed += count;
        };

        // Mic silent throughout; system audio marks a burst at 1.0–1.1s only.
        for (int block = 0; block < 20; block++)
            mixer.Submit(AudioSourceKind.Microphone, Constant(0f, Rate / 10), block * 0.1);
        mixer.Submit(AudioSourceKind.SystemAudio, Constant(0.8f, Rate / 10), 1.0);

        mixer.Drain(2.0);

        // Flatten and find where the burst actually sits on the timeline.
        var all = chunks.SelectMany(c => c.samples).ToArray();
        int firstLoud = Array.FindIndex(all, s => s > 0.5f);
        Assert.True(firstLoud >= 0, "the burst should be present in the mix");

        double burstAt = (double)firstLoud / Rate;
        // It belongs at 1.0s. Appending in arrival order would have put it at 0.
        Assert.InRange(burstAt, 0.98, 1.02);
    }

    [Fact]
    public void RepeatedBurstsDoNotAccumulateDrift()
    {
        using var mixer = new AudioMixer(latencyMilliseconds: 0);
        var mix = Record(mixer);
        for (int block = 0; block < 100; block++)
            mixer.Submit(AudioSourceKind.Microphone, Constant(0.05f, Rate / 10), block * 0.1);

        // One short system burst per second for ten seconds. Arrival-order
        // appending would compress ten bursts into one second of audio.
        for (int second = 0; second < 10; second++)
            mixer.Submit(AudioSourceKind.SystemAudio, Constant(0.6f, Rate / 20), second * 1.0);

        mixer.Drain(10.0);
        Assert.InRange(mixer.Duration.TotalSeconds, 9.9, 10.1);
        // Each burst at the top of its own second, the last as exact as the first.
        for (int second = 0; second < 10; second++)
        {
            Assert.Equal(0.65f, At(mix, second + 0.02), 3);
            Assert.Equal(0.05f, At(mix, second + 0.5), 3);
        }
    }

    [Fact]
    public void AbsurdTimestampCannotAllocateUnboundedSilence()
    {
        using var mixer = new AudioMixer(latencyMilliseconds: 0);
        mixer.Submit(AudioSourceKind.Microphone, Constant(0.1f, Rate / 10), 0.0);
        // A clock glitch claiming an hour into the future must be clamped.
        mixer.Submit(AudioSourceKind.Microphone, Constant(0.1f, Rate / 10), 3600.0);
        mixer.Drain(3700.0, flush: true);

        Assert.True(mixer.Duration.TotalSeconds <= AudioConstants.MaxGapSeconds + 2,
            $"gap should be clamped, got {mixer.Duration.TotalSeconds:F1}s");
    }

    [Fact]
    public void MixingRunsBehindRealTimeToAbsorbLateAudio()
    {
        using var mixer = new AudioMixer();   // default 400 ms latency
        mixer.Submit(AudioSourceKind.Microphone, Constant(0.1f, Rate), 0.0);

        // At one second of clock, only the audio older than the latency window
        // should have been mixed.
        mixer.Drain(1.0);
        Assert.InRange(mixer.Duration.TotalSeconds, 0.55, 0.65);

        // Flushing takes the remainder.
        mixer.Drain(1.0, flush: true);
        Assert.InRange(mixer.Duration.TotalSeconds, 0.95, 1.05);
    }

    [Fact]
    public void LoudestSourceDecidesTheSpeakerLabel()
    {
        using var mixer = new AudioMixer(latencyMilliseconds: 0);
        // 0–1s: the user talks. 1–2s: the far side talks. Draining after each
        // block mirrors the real capture timer — a single drain at the end would
        // produce one energy frame spanning both speakers, which is genuinely
        // ambiguous rather than a labelling failure.
        for (int block = 0; block < 20; block++)
        {
            bool userTalking = block < 10;
            mixer.Submit(AudioSourceKind.Microphone,
                         Constant(userTalking ? 0.4f : 0.01f, Rate / 10), block * 0.1);
            mixer.Submit(AudioSourceKind.SystemAudio,
                         Constant(userTalking ? 0.01f : 0.4f, Rate / 10), block * 0.1);
            mixer.Drain((block + 1) * 0.1);
        }
        mixer.Drain(2.0, flush: true);

        Assert.Equal(Speaker.Me, mixer.Energy.SpeakerBetween(0.1, 0.9));
        Assert.Equal(Speaker.Others, mixer.Energy.SpeakerBetween(1.1, 1.9));
        Assert.Equal(Speaker.Unknown, mixer.Energy.SpeakerBetween(50.0, 51.0));
    }
}
