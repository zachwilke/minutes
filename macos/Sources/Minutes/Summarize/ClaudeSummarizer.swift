import Foundation

enum ClaudeError: LocalizedError {
    case binaryMissing
    case emptyResponse
    case notAuthenticated(String)
    case reported(status: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "The `claude` CLI was not found. Install Claude Code and sign in, then try again."
        case .emptyResponse:
            return "Claude returned an empty summary."
        case .notAuthenticated(let detail):
            return "Claude could not authenticate. Run `claude` in a terminal and sign in. \(detail)"
        case .reported(let status, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "Claude exited with status \(status)." }
            return "Claude reported an error: \(String(trimmed.suffix(600)))"
        }
    }
}

/// Turns a transcript plus your own notes into a structured summary by shelling
/// out to the `claude` CLI, which authenticates with your Claude subscription —
/// no API key and no per-token billing.
struct ClaudeSummarizer {
    /// Keeps prompts to a sane size. A three-hour meeting still fits well within
    /// this; beyond it we drop the middle and say so rather than silently failing.
    private static let maxTranscriptCharacters = 600_000

    /// The notes, and — for a meeting that arrived with only a placeholder name
    /// — a title, written in the same run rather than a second one.
    struct Result: Sendable {
        var notes: String
        var title: String?
    }

    func summarize(meeting: Meeting, template: SummaryTemplate) async throws -> Result {
        guard let binary = ToolLocator.find("claude") else { throw ClaudeError.binaryMissing }

        let language = AppSettings.shared.notesLanguage
        let wantTitle = MeetingTitle.needsGeneratedTitle(meeting)
        let prompt = Self.buildPrompt(meeting: meeting, template: template,
                                      notesLanguage: language.isEmpty ? nil : language,
                                      wantTitle: wantTitle,
                                      userName: AppSettings.shared.myName)
        Log.info("Summarizing \(meeting.id) with template \(template.id) (\(prompt.count) chars)")

        let arguments = [
            "-p",
            "--model", AppSettings.shared.claudeModel,
            "--output-format", "text"
        ] + ClaudeInvocation.arguments(systemPrompt: Self.systemPrompt)

        let output = try await Shell.run(executable: binary,
                                        arguments: arguments,
                                        standardInput: prompt,
                                        environment: ToolLocator.enrichedEnvironment(),
                                        // Run outside any project so it can't pick
                                        // up an unrelated CLAUDE.md as context.
                                        currentDirectory: AppPaths.supportRoot,
                                        // Generous — a long meeting on a slow model
                                        // takes minutes — but finite, so a stalled
                                        // run cannot hold the pipeline forever.
                                        timeout: 900)

        guard output.status == 0 else {
            let detail = output.standardError.isEmpty ? output.standardOutput : output.standardError
            throw ClaudeInvocation.failure(status: output.status, detail: detail)
        }

        let reply = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = wantTitle ? Self.splitTitle(reply) : Result(notes: reply, title: nil)
        guard !result.notes.isEmpty else { throw ClaudeError.emptyResponse }
        return result
    }

    /// Takes the "Title: …" line off the top of a reply that was asked for one.
    /// A reply without it is all notes, and the meeting keeps its placeholder.
    static func splitTitle(_ reply: String) -> Result {
        var lines = reply.components(separatedBy: .newlines)
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return Result(notes: reply, title: nil)
        }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        guard first.lowercased().hasPrefix("title:") else { return Result(notes: reply, title: nil) }
        lines.removeSubrange(0...index)
        let notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(notes: notes, title: MeetingTitle.sanitize(first))
    }

    // MARK: - Prompt construction

    // Prompt text is generated from shared/prompts/summary.json so the Windows
    // port uses the same words. Edit the JSON, then run
    // macos/Scripts/generate-prompts.py.
    static let systemPrompt = SharedPrompts.Summary.systemPrompt
    static let notesGuidance = SharedPrompts.Summary.notesGuidance
    static let notesNone = SharedPrompts.Summary.notesNone
    static let transcriptGuidance = SharedPrompts.Summary.transcriptGuidance
    static let closingGuidance = SharedPrompts.Summary.closingGuidance

    /// `notesLanguage` names the language to write in; nil follows the meeting.
    /// `wantTitle` adds the shared title instruction, for a meeting with only a
    /// placeholder name.
    static func buildPrompt(meeting: Meeting, template: SummaryTemplate,
                            notesLanguage: String? = nil,
                            wantTitle: Bool = false, userName: String? = nil) -> String {
        var sections: [String] = []

        let formatter = DateFormatter()
        // Fixed English names, as the Windows port writes them: the prompt is
        // English, and a German Mac otherwise sent "Montag".
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"

        var metadata = [
            "- Title: \(meeting.displayTitle)",
            "- Date: \(formatter.string(from: meeting.startedAt))",
            "- Duration: \(meeting.durationLabel)"
        ]
        if let app = meeting.detectedAppName {
            metadata.append("- Platform: \(app)")
        }
        if !meeting.attendees.isEmpty {
            metadata.append("- Invited: \(meeting.attendees.joined(separator: ", "))")
        }
        // Whose recording this is, so "You" has a name in the notes.
        if let userName = userName?.trimmingCharacters(in: .whitespacesAndNewlines), !userName.isEmpty {
            metadata.append(SharedPrompts.Summary.recordedByLine
                .replacingOccurrences(of: "{{name}}", with: userName)
                .replacingOccurrences(of: "{{label}}", with: meeting.label(for: .me)))
        }

        sections.append("""
        # Meeting to summarize

        ## Metadata
        \(metadata.joined(separator: "\n"))
        """)

        // The user's notes come before the transcript deliberately: they set the
        // priorities, and the transcript is evidence to flesh them out. This is
        // the whole point of taking notes during the call.
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty {
            sections.append("""
            ## My notes
            \(Self.notesNone)
            """)
        } else {
            let fence = Self.fence(for: notes)
            sections.append("""
            ## My notes
            \(Self.notesGuidance)

            \(fence)
            \(notes)
            \(fence)
            """)
        }

        let transcript = truncated(meeting.transcriptText)
        let fence = Self.fence(for: transcript)
        sections.append("""
        ## Transcript
        \(Self.transcriptGuidance)

        \(fence)
        \(transcript)
        \(fence)
        """)

        var produce = """
        ## What to produce
        \(template.instructions)

        \(Self.closingGuidance)
        """
        if let notesLanguage {
            produce += "\n\n" + SharedPrompts.Summary.languageInstruction
                .replacingOccurrences(of: "{{language}}", with: notesLanguage)
        }
        if wantTitle {
            produce += "\n\n" + SharedPrompts.Summary.titleInstruction
        }
        sections.append(produce)

        return sections.joined(separator: "\n\n")
    }

    /// A code fence longer than any run of backticks in `text`, so content that
    /// itself contains ``` — pasted code, a quoted Markdown note — cannot close
    /// the block early and spill into the instructions. Three in the usual case.
    static func fence(for text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// Drops the middle of a very long transcript, keeping the opening and the
    /// close — where framing and next steps almost always live.
    private static func truncated(_ text: String) -> String {
        guard text.count > maxTranscriptCharacters else { return text }
        let keep = maxTranscriptCharacters / 2
        let head = String(text.prefix(keep))
        let tail = String(text.suffix(keep))
        return head
            + "\n\n[... middle of the transcript omitted because the recording was unusually long ...]\n\n"
            + tail
    }
}
