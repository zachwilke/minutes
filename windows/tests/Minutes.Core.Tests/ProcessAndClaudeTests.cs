using System.Text.RegularExpressions;
using Minutes.Core.Pipeline;

namespace Minutes.Core.Tests;

public class ProcessAndClaudeTests
{
    private static string RepoRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null;
             directory = directory.Parent)
            if (Directory.Exists(Path.Combine(directory.FullName, "shared", "prompts")))
                return directory.FullName;
        throw new DirectoryNotFoundException("repository root not found");
    }

    /// <summary>
    /// The lockdown flags are a security property, so both platforms must pass
    /// exactly the same ones. Read straight from the Swift source.
    /// </summary>
    [Fact]
    public void IsolationFlagsMatchMacOS()
    {
        string swift = File.ReadAllText(Path.Combine(RepoRoot(), "macos", "Sources", "Minutes",
                                                     "Summarize", "ClaudeInvocation.swift"));
        string block = swift[swift.IndexOf("static let isolation", StringComparison.Ordinal)..];
        block = block[(block.IndexOf("= [", StringComparison.Ordinal) + 3)..];
        block = block[..block.IndexOf(']')];
        var swiftFlags = Regex.Matches(block, "\"([^\"]*)\"").Select(m => m.Groups[1].Value).ToArray();
        Assert.Equal(swiftFlags, ClaudeRunner.Isolation);
        Assert.Contains("--no-session-persistence", ClaudeRunner.Isolation);
    }

    [Fact]
    public void OnlySignInProblemsReadAsSignInProblems()
    {
        Assert.Contains("could not authenticate",
            ClaudeRunner.Failure(1, "Invalid API key · Please run /login").Message);
        var rateLimited = ClaudeRunner.Failure(1, "API Error: 429 rate_limit_error");
        Assert.DoesNotContain("authenticate", rateLimited.Message);
        Assert.Contains("429", rateLimited.Message);
    }

    [Fact]
    public void NpmShimResolvesToTheScriptBehindIt()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"npm-{Guid.NewGuid():N}");
        string script = Path.Combine(directory, "node_modules", "@anthropic-ai", "claude-code", "cli.js");
        Directory.CreateDirectory(Path.GetDirectoryName(script)!);
        try
        {
            File.WriteAllText(Path.Combine(directory, "claude.cmd"), "@node cli.js %*");
            Assert.Null(ProcessRunner.ResolveNpmShim(Path.Combine(directory, "claude.cmd")));
            File.WriteAllText(script, "");
            Assert.Equal(script, ProcessRunner.ResolveNpmShim(Path.Combine(directory, "claude.cmd")));
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public async Task CallerCancellationIsNotReportedAsATimeout()
    {
        if (OperatingSystem.IsWindows()) return;   // uses /bin/sleep
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        var started = DateTime.UtcNow;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            ProcessRunner.RunAsync("/bin/sleep", ["30"], timeout: TimeSpan.FromMinutes(5),
                                   cancellationToken: cancel.Token));
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(5), "the child must be killed");
    }

    [Fact]
    public async Task TimeoutCoversAChildThatNeverReadsItsInput()
    {
        if (OperatingSystem.IsWindows()) return;
        var started = DateTime.UtcNow;
        await Assert.ThrowsAsync<TimeoutException>(() =>
            ProcessRunner.RunAsync("/bin/sleep", ["30"], standardInput: new string('x', 2_000_000),
                                   timeout: TimeSpan.FromSeconds(1)));
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task ChildExitingBeforeReadingInputIsNotAnError()
    {
        if (OperatingSystem.IsWindows()) return;
        var result = await ProcessRunner.RunAsync("/usr/bin/true", [],
                                                  standardInput: new string('x', 2_000_000));
        Assert.Equal(0, result.ExitCode);
    }
}
