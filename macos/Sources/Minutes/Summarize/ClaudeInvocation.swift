import Foundation

/// Flags shared by every headless `claude -p` run.
///
/// Everything we send is text generation over content we supply, and that
/// content includes whatever anyone said on a call. So the run gets no tools at
/// all, rather than a denylist: `--disallowed-tools` only blocks the names it
/// lists, and verified against CLI 2.1 that left Skill, Workflow, CronCreate,
/// RemoteTrigger, SendMessage and every MCP tool available to a transcript that
/// asked for them.
enum ClaudeInvocation {
    static let isolation: [String] = [
        // An empty list disables every built-in tool.
        "--tools", "",
        // Ignore the user's MCP servers; we pass none of our own.
        "--strict-mcp-config",
        // Skip user, project and local settings, so a user's allow rules,
        // bypassPermissions default or hooks never see meeting content.
        // Authentication is not a setting and still works.
        "--setting-sources", "",
        // Otherwise every transcript is also kept as a session log under
        // ~/.claude/projects/, outliving the meeting when it is deleted.
        "--no-session-persistence"
    ]

    /// Everything a run needs besides the model and output format: our own
    /// system prompt *in place of* Claude Code's, no skills, and the isolation
    /// flags above.
    ///
    /// `--append-system-prompt` kept Claude Code's whole default prompt — its
    /// instructions for editing code, using tools and talking to a terminal —
    /// and added ours after it. Measured with `--output-format json` on CLI
    /// 2.1.329: a one-line question cost 4,258 input tokens that way and 1,037
    /// with the prompt replaced and skills off. That 3,200 tokens rode on every
    /// summary and every chat message and was never used: these runs generate
    /// text from content we supply, with no tools. (`--bare` would cut further,
    /// but it skips keychain reads, which is where a subscription sign-in lives.)
    static func arguments(systemPrompt: String) -> [String] {
        ["--system-prompt", systemPrompt, "--disable-slash-commands"] + isolation
    }

    /// For runs whose instructions are all in the message: the connection check.
    static let plainSystemPrompt = "Follow the instructions in the message exactly, and reply with only what it asks for."

    /// Classifies a failed run. Only an explicit sign-in problem is reported as
    /// one; rate limits, usage caps and oversized prompts say what they are.
    static func failure(status: Int32, detail: String) -> Error {
        let lowered = detail.lowercased()
        let authMarkers = ["not logged in", "please run /login", "invalid api key",
                           "authentication", "oauth token", "login required", "expired"]
        if authMarkers.contains(where: lowered.contains) {
            return ClaudeError.notAuthenticated(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ClaudeError.reported(status: status, detail: detail)
    }
}
