namespace Minutes.Core.Audio;

/// <summary>
/// Resamples arbitrary device audio to 16 kHz mono, band-limiting as it goes.
/// </summary>
/// <remarks>
/// macOS got this free from AVAudioConverter; Windows has no equivalent, so it is
/// written here. It is a windowed-sinc interpolator rather than plain linear
/// interpolation, which matters: decimating 48 kHz to 16 kHz without a low-pass
/// folds everything above 8 kHz back down into the speech band as alias tones,
/// and Whisper hears the result as noise.
///
/// State carries across calls, so consecutive buffers stitch without a click at
/// the seam.
/// </remarks>
public sealed class WindowedSincResampler
{
    private const int HalfTaps = 16;
    private const int Taps = HalfTaps * 2;

    private readonly double _ratio;
    private readonly float[] _kernel;
    private readonly int _phases;
    private readonly float[] _history = new float[Taps];
    private double _position;
    private bool _primed;

    public int InputRate { get; }
    public int OutputRate { get; }

    public WindowedSincResampler(int inputRate, int outputRate = AudioConstants.SampleRate)
    {
        if (inputRate <= 0) throw new ArgumentOutOfRangeException(nameof(inputRate));
        if (outputRate <= 0) throw new ArgumentOutOfRangeException(nameof(outputRate));

        InputRate = inputRate;
        OutputRate = outputRate;
        _ratio = (double)inputRate / outputRate;

        // Cut just below the lower Nyquist, with margin for the window's skirt.
        double cutoff = Math.Min(inputRate, outputRate) * 0.45 / inputRate;
        _phases = 512;
        _kernel = BuildKernel(cutoff, _phases);
    }

    /// <summary>Precomputed sinc·Blackman taps, one set per sub-sample phase.</summary>
    private static float[] BuildKernel(double cutoff, int phases)
    {
        var kernel = new float[phases * Taps];
        for (int phase = 0; phase < phases; phase++)
        {
            double offset = (double)phase / phases;
            for (int tap = 0; tap < Taps; tap++)
            {
                double x = tap - HalfTaps + 1 - offset;
                double sinc = x == 0 ? 2 * cutoff : Math.Sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
                // Blackman window — cheap and its stopband is deep enough that
                // aliasing stays well below the noise floor of a meeting.
                double w = tap / (double)(Taps - 1);
                double window = 0.42 - 0.5 * Math.Cos(2 * Math.PI * w) + 0.08 * Math.Cos(4 * Math.PI * w);
                kernel[phase * Taps + tap] = (float)(sinc * window);
            }
        }

        // Normalise each phase to unity gain at DC so amplitude is preserved.
        for (int phase = 0; phase < phases; phase++)
        {
            double sum = 0;
            for (int tap = 0; tap < Taps; tap++) sum += kernel[phase * Taps + tap];
            if (Math.Abs(sum) < 1e-9) continue;
            for (int tap = 0; tap < Taps; tap++) kernel[phase * Taps + tap] /= (float)sum;
        }
        return kernel;
    }

    /// <summary>
    /// Resamples one block, appending to <paramref name="output"/>. Returns the
    /// number of samples written.
    /// </summary>
    public int Resample(ReadOnlySpan<float> input, List<float> output)
    {
        if (input.Length == 0) return 0;

        // Prime the history with the leading sample so the first output is not
        // an artefact of an all-zero filter state.
        if (!_primed)
        {
            _history.AsSpan().Fill(input[0]);
            _primed = true;
        }

        int written = 0;
        // _position is in input samples relative to the current input block,
        // and may be negative while the filter still needs history.
        while (true)
        {
            int center = (int)Math.Floor(_position);
            double frac = _position - center;
            // The highest tap reads input[center + HalfTaps], so the block must
            // hold that index. Using > here read one sample past the end — 48 kHz
            // stepped over the boundary by luck, passthrough landed exactly on it.
            if (center + HalfTaps >= input.Length) break;

            int phase = (int)(frac * _phases);
            if (phase >= _phases) phase = _phases - 1;
            int kernelBase = phase * Taps;

            float sum = 0;
            for (int tap = 0; tap < Taps; tap++)
            {
                int index = center - HalfTaps + 1 + tap;
                float sample = index < 0
                    ? _history[_history.Length + index]   // reach back into history
                    : input[index];
                sum += sample * _kernel[kernelBase + tap];
            }

            output.Add(sum);
            written++;
            _position += _ratio;
        }

        // Retain the tail for the next block and rebase the read position.
        // History is oldest-first: slide what stays to the front, dropping the
        // oldest, then append the newest. (Sliding it the other way kept the
        // oldest samples and discarded the newest whenever a block was shorter
        // than the filter — 8-sample blocks lost ~85% of a tone's level.)
        int keep = Math.Min(Taps, input.Length);
        _history.AsSpan(keep).CopyTo(_history);
        input[^keep..].CopyTo(_history.AsSpan(Taps - keep));
        _position -= input.Length;
        return written;
    }

    /// <summary>Resets filter state; use when capture restarts.</summary>
    public void Reset()
    {
        Array.Clear(_history);
        _position = 0;
        _primed = false;
    }
}
