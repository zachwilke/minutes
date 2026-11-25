namespace Minutes.Core.Tests;

/// <summary>Mirror of the macOS EchoLabelTests: a call on laptop speakers.</summary>
public class EchoLabelTests
{
    private static EnergyTrack SpeakerphoneTrack()
    {
        var track = new EnergyTrack();
        for (int i = 0; i < 400; i++)
        {
            float t = i / 10f;
            bool userTalking = t >= 20 && t < 30;
            float system = userTalking ? 0.002f : 0.08f * (1 + 0.3f * MathF.Sin(t));
            float mic = (userTalking ? 0.12f : 0.004f) + 0.8f * system;
            track.Add(t, mic, system);
        }
        return track;
    }

    [Fact]
    public void FarSideThroughSpeakersIsThemNotSpeaker()
    {
        var track = SpeakerphoneTrack();
        float coupling = track.EchoCoupling();
        Assert.InRange(coupling, 0.7f, 0.9f);
        Assert.NotEqual(Speaker.Others, track.SpeakerBetween(2, 8));
        Assert.Equal(Speaker.Others, track.SpeakerBetween(2, 8, coupling));
        Assert.Equal(Speaker.Me, track.SpeakerBetween(22, 28, coupling));
    }
}
