using System.Diagnostics;
using System.Text;

namespace Minutes.Core.Pipeline;

public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError);

/// <summary>
/// Runs a child process, draining both pipes concurrently.
/// </summary>
/// <remarks>
/// Both pipes must be read while the process runs: whisper logs heavily to
/// stderr, and a full pipe buffer would deadlock it. The optional line callbacks
/// exist so progress and streamed replies can surface before the process exits.
/// </remarks>
public static class ProcessRunner
{
    public static async Task<ProcessResult> RunAsync(
        string executable,
        IEnumerable<string> arguments,
        string? standardInput = null,
        string? workingDirectory = null,
        IDictionary<string, string>? environment = null,
        TimeSpan? timeout = null,
        Action<string>? onStandardOutputLine = null,
        Action<string>? onStandardErrorLine = null,
        CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = workingDirectory ?? Environment.CurrentDirectory
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        if (environment is not null)
            foreach (var (key, value) in environment) startInfo.Environment[key] = value;

        using var process = new Process { StartInfo = startInfo };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stdout.Append(e.Data).Append('\n');
            onStandardOutputLine?.Invoke(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null) return;
            stderr.Append(e.Data).Append('\n');
            onStandardErrorLine?.Invoke(e.Data);
        };

        if (!process.Start())
            throw new InvalidOperationException($"could not start {Path.GetFileName(executable)}");

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        // The deadline runs from launch: a child that never reads its input
        // would otherwise stall the write below before any timeout applied.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (timeout is not null) deadline.CancelAfter(timeout.Value);

        try
        {
            if (standardInput is not null)
            {
                try
                {
                    await process.StandardInput.WriteAsync(standardInput.AsMemory(), deadline.Token);
                    await process.StandardInput.FlushAsync(deadline.Token);
                }
                catch (IOException)
                {
                    // The child exited without reading everything — a bad flag,
                    // a missing runtime. Its exit code and stderr say why.
                }
            }
            try { process.StandardInput.Close(); } catch (IOException) { /* already closed */ }

            await process.WaitForExitAsync(deadline.Token);
        }
        catch (OperationCanceledException)
        {
            // Without a deadline a wedged tool blocks forever; and cancelling
            // must stop the tool, not just stop waiting for it.
            try { process.Kill(entireProcessTree: true); } catch { /* already gone */ }
            // The caller's own cancellation is a cancellation, not a timeout —
            // the linked token made the two indistinguishable before.
            cancellationToken.ThrowIfCancellationRequested();
            throw new TimeoutException(
                $"{Path.GetFileName(executable)} exceeded {timeout!.Value.TotalSeconds:F0}s");
        }

        return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
    }

    /// <summary>
    /// Finds the claude CLI and how to launch it. The native installer gives a
    /// claude.exe; an npm install gives only a claude.cmd shim, and running a
    /// batch file sends every argument through cmd.exe's quoting — which the
    /// multi-line system prompt, quotes and all, does not survive. So a shim is
    /// resolved to the script behind it and run with node directly.
    /// </summary>
    public static (string File, string[] PrefixArguments)? LocateClaude()
    {
        if (Locate("claude") is { } exe) return (exe, []);
        if (!OperatingSystem.IsWindows()) return null;

        var shimDirectories = new List<string>
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm")
        };
        shimDirectories.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        foreach (var directory in shimDirectories)
        {
            string shim = Path.Combine(directory, "claude.cmd");
            if (File.Exists(shim) && ResolveNpmShim(shim) is { } script && Locate("node") is { } node)
                return (node, [script]);
        }
        return null;
    }

    /// <summary>The CLI script an npm claude.cmd shim launches, if present.</summary>
    public static string? ResolveNpmShim(string shimPath)
    {
        string? directory = Path.GetDirectoryName(shimPath);
        if (directory is null) return null;
        string script = Path.Combine(directory, "node_modules", "@anthropic-ai", "claude-code", "cli.js");
        return File.Exists(script) ? script : null;
    }

    /// <summary>
    /// Finds a command line tool. A GUI app inherits a bare PATH, so the usual
    /// install locations are checked directly before falling back to PATH.
    /// </summary>
    public static string? Locate(string name)
    {
        string executable = OperatingSystem.IsWindows() ? name + ".exe" : name;

        var candidates = new List<string>();
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (OperatingSystem.IsWindows())
        {
            candidates.Add(Path.Combine(AppContext.BaseDirectory, executable));          // bundled
            candidates.Add(Path.Combine(AppContext.BaseDirectory, "whisper", executable));
            candidates.Add(Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData), "Programs", executable));
            candidates.Add(Path.Combine(home, ".local", "bin", executable));
            candidates.Add(Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.ProgramFiles), "nodejs", executable));
        }
        else
        {
            candidates.AddRange(["/opt/homebrew/bin/" + executable, "/usr/local/bin/" + executable,
                                 "/usr/bin/" + executable,
                                 Path.Combine(home, ".local", "bin", executable)]);
        }

        foreach (var candidate in candidates)
            if (File.Exists(candidate)) return candidate;

        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "")
                 .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            string candidate = Path.Combine(directory, executable);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
