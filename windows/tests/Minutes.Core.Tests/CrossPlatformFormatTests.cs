namespace Minutes.Core.Tests;

/// <summary>
/// Verifies the Windows format code against files the shipping macOS app
/// actually wrote.
/// </summary>
/// <remarks>
/// A library must open on either platform (shared/spec/meeting-format.md), and
/// the only way to know that is to read the other implementation's output rather
/// than our own. The audio and meeting.json fixtures came out of a real recorded
/// meeting; macos-energy.bin is written to the same little-endian float32 triple
/// layout (see macos/Sources/Minutes/Audio/EnergyTrack.swift).
/// </remarks>
public class CrossPlatformFormatTests
{
    private static string Fixture(string name) => Path.Combine(AppContext.BaseDirectory, "fixtures", name);

    [Fact]
    public void ReadsEnergyTrackWrittenByMacOS()
    {
        var track = EnergyTrack.Read(Fixture("macos-energy.bin"));

        // The file holds 624 bytes = 52 twelve-byte triples.
        Assert.Equal(52, track.Count);

        // Frames are time-ordered and start at zero.
        Assert.Equal(0f, track.Frames[0].Time, 5);
        for (int i = 1; i < track.Count; i++)
            Assert.True(track.Frames[i].Time >= track.Frames[i - 1].Time,
                        "frames must be time-ordered for the binary search to hold");

        // The recording was a microphone test: mic energy present, system silent.
        Assert.True(track.Frames.Any(f => f.Mic > 0.001f), "expected microphone energy");
        Assert.True(track.Frames.All(f => f.System == 0f), "system audio was silent in this recording");

        // And it should therefore label the speaker as the user, matching the
        // segment labels macOS wrote into meeting.json for the same audio.
        Assert.Equal(Speaker.Me, track.SpeakerBetween(1.0, 4.0));
    }

    [Fact]
    public void RoundTripsEnergyTrackByteForByteWithMacOSLayout()
    {
        var original = File.ReadAllBytes(Fixture("macos-energy.bin"));
        var track = EnergyTrack.Read(Fixture("macos-energy.bin"));

        string temp = Path.Combine(Path.GetTempPath(), $"energy-{Guid.NewGuid():N}.bin");
        try
        {
            track.Write(temp);
            Assert.Equal(original, File.ReadAllBytes(temp));
        }
        finally { File.Delete(temp); }
    }

    [Fact]
    public void MacOSWavHeaderMatchesWhatWeWrite()
    {
        var macHeader = new byte[44];
        using (var stream = File.OpenRead(Fixture("macos-audio.wav")))
            Assert.Equal(44, stream.Read(macHeader, 0, 44));

        // Write an equivalent file of the same length and compare headers: the
        // two writers must agree on every field, not just be independently valid.
        long frames = (new FileInfo(Fixture("macos-audio.wav")).Length - 44) / 2;
        string temp = Path.Combine(Path.GetTempPath(), $"wav-{Guid.NewGuid():N}.wav");
        try
        {
            using (var writer = new WavWriter(temp))
                writer.Append(new float[frames]);

            var ourHeader = new byte[44];
            using (var stream = File.OpenRead(temp))
                stream.Read(ourHeader, 0, 44);

            Assert.Equal(macHeader, ourHeader);
        }
        finally { File.Delete(temp); }
    }

    [Fact]
    public void RepairsAZeroLengthHeaderTheWayMacOSDid()
    {
        // Reproduce the real failure: a force-quit left a valid payload behind a
        // header claiming zero frames, and the audio was only recoverable because
        // the size could be derived from the file length.
        string temp = Path.Combine(Path.GetTempPath(), $"broken-{Guid.NewGuid():N}.wav");
        try
        {
            File.Copy(Fixture("macos-audio.wav"), temp, overwrite: true);
            using (var stream = new FileStream(temp, FileMode.Open, FileAccess.Write))
            {
                stream.Position = 40;                  // data chunk size
                stream.Write(new byte[4]);             // claim zero
            }

            var recovered = WavWriter.RepairHeaderIfNeeded(temp);
            Assert.NotNull(recovered);
            // 89,430 frames at 16 kHz ≈ 5.59 s.
            Assert.InRange(recovered!.Value.TotalSeconds, 5.5, 5.7);

            // Repaired file must now match the original byte for byte.
            Assert.Equal(File.ReadAllBytes(Fixture("macos-audio.wav")), File.ReadAllBytes(temp));
        }
        finally { File.Delete(temp); }
    }

    [Fact]
    public void RepairIsANoOpOnAHealthyFile()
    {
        string temp = Path.Combine(Path.GetTempPath(), $"healthy-{Guid.NewGuid():N}.wav");
        try
        {
            File.Copy(Fixture("macos-audio.wav"), temp, overwrite: true);
            var before = File.ReadAllBytes(temp);
            var result = WavWriter.RepairHeaderIfNeeded(temp);
            Assert.NotNull(result);
            Assert.Equal(before, File.ReadAllBytes(temp));
        }
        finally { File.Delete(temp); }
    }
}
