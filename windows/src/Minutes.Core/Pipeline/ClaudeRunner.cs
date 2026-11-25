using System.Text;
using System.Text.Json;
using Minutes.Core.Meetings;
using Minutes.Core.Prompts;

namespace Minutes.Core.Pipeline;

public sealed record ClaudeAccount(string? Email, string? Organization, string? Subscription, string? AuthMethod);
public sealed record ClaudeAuthStatus(bool LoggedIn, ClaudeAccount Account);

/// <summary>
/// Writes notes and answers questions through the `claude` CLI, which
/// authenticates with the user's Claude subscription — no API key.
/// </summary>
/// <remarks>
/// Identical to the macOS integration, including the stream-json parsing: the
/// CLI is the same program on Windows, so the shapes verified there hold here.
/// </remarks>
public sealed class ClaudeRunner
{
    public string Model { get; init; } = "sonnet";
    public string? ExecutablePath { get; init; }

    /// <summary>
    /// Flags for every headless run, matching macOS (ClaudeInvocation.swift).
    /// The content includes whatever anyone said on a call, so the run gets no
    /// tools at all rather than a denylist — `--disallowed-tools` only blocks
    /// what it names, and left Skill, Workflow, CronCreate, RemoteTrigger and
    /// every MCP tool reachable. User settings (allow rules, hooks) are skipped,
    /// and the run is not kept as a session log under ~/.claude/projects.
    /// </summary>
    public static readonly string[] Isolation =
        ["--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence"];

    private (string File, string[] Prefix) Launch => ExecutablePath is { } path
        ? (path, [])
        : ProcessRunner.LocateClaude() ?? throw new FileNotFoundException(
            "The claude CLI was not found. Install Claude Code and sign in, then try again.");

    private Task<ProcessResult> RunClaudeAsync(IEnumerable<string> arguments, string? standardInput,
                                               TimeSpan timeout, Action<string>? onLine,
                                               CancellationToken cancellationToken)
    {
        var (file, prefix) = Launch;
        return ProcessRunner.RunAsync(file, [.. prefix, .. arguments],
            standardInput: standardInput,
            workingDirectory: AppPaths.SupportRoot,
            timeout: timeout,
            onStandardOutputLine: onLine,
            cancellationToken: cancellationToken);
    }

    /// <summary>
    /// Only an explicit sign-in problem is reported as one; rate limits, usage
    /// caps and oversized prompts say what they are.
    /// </summary>
    public static Exception Failure(int exitCode, string detail)
    {
        string lowered = detail.ToLowerInvariant();
        string[] authMarkers = ["not logged in", "please run /login", "invalid api key",
                                "authentication", "oauth token", "login required", "expired"];
        if (authMarkers.Any(lowered.Contains))
            return new InvalidOperationException(
                $"Claude could not authenticate. Run `claude` in a terminal and sign in. {detail.Trim()}");
        string trimmed = detail.Trim();
        return new InvalidOperationException(trimmed.Length == 0
            ? $"Claude exited with status {exitCode}."
            : $"Claude reported an error: {(trimmed.Length > 600 ? trimmed[^600..] : trimmed)}");
    }

    /// <summary>
    /// Reads the sign-in state. Costs no tokens, so it is safe to call on a
    /// timer or when a settings pane opens.
    /// </summary>
    public async Task<ClaudeAuthStatus?> GetAuthStatusAsync(CancellationToken cancellationToken = default)
    {
        var result = await RunClaudeAsync(["auth", "status"], null, TimeSpan.FromSeconds(20), null,
                                          cancellationToken);

        int brace = result.StandardOutput.IndexOf('{');
        if (brace < 0) return null;
        try
        {
            using var document = JsonDocument.Parse(result.StandardOutput[brace..]);
            var root = document.RootElement;
            return new ClaudeAuthStatus(
                root.TryGetProperty("loggedIn", out var logged) && logged.GetBoolean(),
                new ClaudeAccount(
                    Text(root, "email"), Text(root, "orgName"),
                    Text(root, "subscriptionType"), Text(root, "authMethod")));
        }
        catch (JsonException) { return null; }
    }

    private static string? Text(JsonElement element, string name)
        => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    /// <summary>Generates the notes for a meeting.</summary>
    public async Task<string> SummarizeAsync(Meeting meeting, SummaryTemplate template,
                                             string? notesLanguage = null,
                                             CancellationToken cancellationToken = default)
    {
        string prompt = SummaryPrompt.Build(meeting, template, notesLanguage);
        string[] arguments =
        [
            "-p", "--model", Model, "--output-format", "text",
            "--append-system-prompt", SummaryPrompt.SystemPrompt,
            .. Isolation
        ];

        var result = await RunClaudeAsync(arguments, prompt, TimeSpan.FromMinutes(15), null,
                                          cancellationToken);

        string summary = result.StandardOutput.Trim();
        if (result.ExitCode != 0)
            throw Failure(result.ExitCode,
                result.StandardError.Length > 0 ? result.StandardError : result.StandardOutput);
        if (summary.Length == 0) throw new InvalidOperationException("Claude returned an empty summary.");
        return summary;
    }

    /// <summary>
    /// Answers a question about the library, streaming the reply.
    /// </summary>
    /// <remarks>
    /// stream-json shapes were verified against the CLI: text arrives as
    /// {"type":"stream_event","event":{"type":"content_block_delta","delta":{"text":…}}}
    /// and the run ends with a "result" event carrying the whole reply and an
    /// is_error flag. Unknown event types are ignored so a future CLI adding
    /// events does not break chat.
    /// </remarks>
    public async Task<string> AskAsync(string question, IReadOnlyList<ChatMessage> history,
                                       IReadOnlyList<Meeting> meetings,
                                       Action<string>? onDelta = null,
                                       Guid? focus = null,
                                       CancellationToken cancellationToken = default)
    {
        var context = ChatContextBuilder.Build(question, history, meetings, focus);
        string prompt = ChatPrompt.Assemble(question, history, context.Context);

        string[] arguments =
        [
            "-p", "--model", Model,
            "--output-format", "stream-json", "--include-partial-messages", "--verbose",
            "--append-system-prompt", ChatPrompt.SystemPrompt,
            .. Isolation
        ];

        var streamed = new StringBuilder();
        string? final = null;
        string? failure = null;

        var result = await RunClaudeAsync(arguments, prompt, TimeSpan.FromMinutes(5),
            onLine: line =>
            {
                string trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed[0] != '{') return;
                try
                {
                    using var document = JsonDocument.Parse(trimmed);
                    var root = document.RootElement;
                    if (!root.TryGetProperty("type", out var typeElement)) return;
                    switch (typeElement.GetString())
                    {
                        case "stream_event":
                            if (root.TryGetProperty("event", out var e)
                                && e.TryGetProperty("type", out var et)
                                && et.GetString() == "content_block_delta"
                                && e.TryGetProperty("delta", out var delta)
                                && delta.TryGetProperty("text", out var text))
                            {
                                streamed.Append(text.GetString());
                                onDelta?.Invoke(streamed.ToString());
                            }
                            break;
                        case "result":
                            bool isError = root.TryGetProperty("is_error", out var flag) && flag.GetBoolean();
                            string? payload = Text(root, "result");
                            if (isError) failure = payload ?? "Claude reported an error.";
                            else if (!string.IsNullOrEmpty(payload)) final = payload;
                            break;
                    }
                }
                catch (JsonException) { /* a partial line is not a failure */ }
            },
            cancellationToken: cancellationToken);

        if (failure is not null) throw Failure(result.ExitCode, failure);

        // The final result event carries the complete text; accumulated deltas
        // are the fallback if it never arrived.
        string answer = (final ?? streamed.ToString()).Trim();
        if (answer.Length == 0)
        {
            if (result.ExitCode != 0) throw Failure(result.ExitCode, result.StandardError);
            throw new InvalidOperationException("Claude returned an empty answer.");
        }
        return answer;
    }
}
