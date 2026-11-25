using Minutes.Core.Prompts;

namespace Minutes.Core.Tests;

/// <summary>
/// The cross-platform prompt contract: this port must render every prompt
/// byte-identically to the macOS app.
/// </summary>
/// <remarks>
/// shared/prompts/baseline.txt was produced by the shipping macOS build. It
/// covers the prose, the section scaffolding, the assembly order and the
/// retrieval layering at once — a stronger guarantee than sharing strings, since
/// it tests the composed result rather than the ingredients.
/// </remarks>
public class PromptParityTests
{
    private static string BaselinePath()
    {
        // Walk up to the repository root, so the test does not depend on where
        // the runner was invoked from.
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            string candidate = Path.Combine(directory.FullName, "shared", "prompts", "baseline.txt");
            if (File.Exists(candidate)) return candidate;
            directory = directory.Parent;
        }
        throw new FileNotFoundException("shared/prompts/baseline.txt not found");
    }

    [Fact]
    public void RendersEveryPromptExactlyAsMacOSDoes()
    {
        string expected = File.ReadAllText(BaselinePath()).Replace("\r\n", "\n");
        string actual = PromptAudit.Dump().Replace("\r\n", "\n");

        if (expected == actual) return;

        // Report the first divergence with context: a wall of diff is useless
        // when the difference is one character of whitespace.
        var expectedLines = expected.Split('\n');
        var actualLines = actual.Split('\n');
        for (int i = 0; i < Math.Max(expectedLines.Length, actualLines.Length); i++)
        {
            string e = i < expectedLines.Length ? expectedLines[i] : "<missing>";
            string a = i < actualLines.Length ? actualLines[i] : "<missing>";
            if (e == a) continue;
            Assert.Fail($"""
                         Prompt parity broken at line {i + 1}.

                         macOS   : {Show(e)}
                         Windows : {Show(a)}
                         """);
        }
        Assert.Fail($"lengths differ: macOS {expected.Length}, Windows {actual.Length}");
    }

    /// <summary>Makes trailing and repeated whitespace visible in failures.</summary>
    private static string Show(string line) => line.Replace(" ", "·");

    [Fact]
    public void SharesTheSameSixTemplates()
    {
        Assert.Equal(new[] { "general", "client-call", "discovery", "troubleshooting",
                             "one-on-one", "standup" },
                     SummaryTemplate.All.Select(t => t.Id));
    }

    [Fact]
    public void RecognisesTheSameConferencingApps()
    {
        // The detection table is shared too, so both platforms notice the same
        // apps — a Teams call must be detected on either.
        var apps = SharedPrompts.Detection.Apps;
        Assert.Contains(apps, a => a.Prefix == "us.zoom" && !a.Ambiguous);
        Assert.Contains(apps, a => a.Prefix == "com.microsoft.teams" && !a.Ambiguous);
        Assert.Contains(apps, a => a.Prefix == "com.google.Chrome" && a.Ambiguous);
        Assert.Equal(27, apps.Length);
    }
}
