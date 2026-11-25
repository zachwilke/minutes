using Minutes.Core.Audio;

namespace Minutes.Core.Tests;

public class ResamplerTests
{
    private static float[] Tone(double frequency, int rate, double seconds, double amplitude = 0.5)
    {
        int count = (int)(rate * seconds);
        var samples = new float[count];
        for (int i = 0; i < count; i++)
            samples[i] = (float)(amplitude * Math.Sin(2 * Math.PI * frequency * i / rate));
        return samples;
    }

    private static double Rms(IEnumerable<float> samples)
    {
        double sum = 0; int n = 0;
        foreach (var s in samples) { sum += s * (double)s; n++; }
        return n == 0 ? 0 : Math.Sqrt(sum / n);
    }

    [Fact]
    public void ProducesRoughlyTheExpectedSampleCount()
    {
        var resampler = new WindowedSincResampler(48_000);
        var output = new List<float>();
        // Feed in realistic 10 ms blocks rather than one long buffer.
        for (int block = 0; block < 100; block++)
            resampler.Resample(Tone(1000, 48_000, 0.01), output);

        // One second in, so ~16k samples out; allow a little for filter priming.
        Assert.InRange(output.Count, 15_800, 16_050);
    }

    /// <summary>
    /// Blocks shorter than the filter used to shift history the wrong way,
    /// keeping stale samples: an 8-sample-block tone came out at a seventh of
    /// its level. A WASAPI packet is usually 480 frames, but nothing promises it.
    /// </summary>
    [Fact]
    public void ShortBlocksResampleLikeOneLongBlock()
    {
        var tone = Tone(1000, 48_000, 0.5);
        var resampler = new WindowedSincResampler(48_000);
        var output = new List<float>();
        for (int offset = 0; offset < tone.Length; offset += 8)
            resampler.Resample(tone.AsSpan(offset, Math.Min(8, tone.Length - offset)), output);

        Assert.InRange(Rms(output.Skip(200)), 0.30, 0.38);
    }

    [Fact]
    public void PreservesAmplitudeOfSpeechBandTone()
    {
        var resampler = new WindowedSincResampler(48_000);
        var output = new List<float>();
        resampler.Resample(Tone(1000, 48_000, 0.5), output);

        // A 1 kHz tone is well inside the passband: amplitude should survive.
        double rms = Rms(output.Skip(200));
        Assert.InRange(rms, 0.30, 0.38);   // 0.5 amplitude sine ≈ 0.354 RMS
    }

    [Fact]
    public void AttenuatesToneAboveNyquistInsteadOfAliasing()
    {
        // 10 kHz cannot exist at 16 kHz output (8 kHz Nyquist). Plain linear
        // interpolation would fold it down to 6 kHz as a loud alias tone, which
        // Whisper hears as noise. It must be filtered out instead.
        var resampler = new WindowedSincResampler(48_000);
        var output = new List<float>();
        resampler.Resample(Tone(10_000, 48_000, 0.5), output);

        double rms = Rms(output.Skip(200));
        Assert.True(rms < 0.02, $"expected the out-of-band tone to be suppressed, got RMS {rms:F4}");
    }

    [Fact]
    public void StitchesBlocksWithoutDiscontinuity()
    {
        // A seam between buffers shows up as a click: a single-sample jump far
        // larger than the waveform's natural slope.
        var resampler = new WindowedSincResampler(48_000);
        var output = new List<float>();
        var tone = Tone(500, 48_000, 0.02);
        for (int block = 0; block < 25; block++) resampler.Resample(tone, output);

        double biggestJump = 0;
        for (int i = 300; i < output.Count; i++)
            biggestJump = Math.Max(biggestJump, Math.Abs(output[i] - output[i - 1]));

        // A 500 Hz tone at 16 kHz moves at most ~0.098 per sample at amplitude 0.5.
        Assert.True(biggestJump < 0.15, $"seam discontinuity detected: {biggestJump:F4}");
    }

    [Fact]
    public void HandlesPassthroughRate()
    {
        var resampler = new WindowedSincResampler(16_000);
        var output = new List<float>();
        resampler.Resample(Tone(1000, 16_000, 0.25), output);
        Assert.InRange(output.Count, 3_900, 4_010);
        Assert.InRange(Rms(output.Skip(100)), 0.30, 0.38);
    }
}
