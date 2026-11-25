import Foundation

/// Answers questions about the meeting library through the `claude` CLI.
///
/// Uses `--output-format stream-json --include-partial-messages` so the reply
/// arrives token by token. A chat that sits silent for twenty seconds and then
/// dumps a paragraph feels broken, even when it is working.
struct MeetingChatService {
    struct Answer {
        var text: String
        var groundedIn: [UUID]
    }

    // Generated from shared/prompts/chat.json.
    static let systemPrompt = SharedPrompts.Chat.systemPrompt

    /// Streams an answer. `onDelta` receives the accumulated text so far.
    func ask(question: String,
             history: [ChatMessage],
             meetings: [Meeting],
             focus: UUID? = nil,
             onDelta: @escaping @Sendable (String) -> Void) async throws -> Answer {
        guard let binary = ToolLocator.find("claude") else { throw ClaudeError.binaryMissing }

        let built = MeetingContextBuilder.build(question: question,
                                                history: history,
                                                meetings: meetings,
                                                focus: focus)
        let prompt = Self.assemble(question: question, history: history, context: built.context,
                                   userName: AppSettings.shared.myName)
        Log.info("Chat question over \(built.indexedCount) meetings, "
                 + "\(built.included.count) in full, \(prompt.count) chars"
                 + (built.truncated ? " (truncated)" : ""))

        let accumulator = StreamAccumulator(onDelta: onDelta)

        let output = try await Shell.run(
            executable: binary,
            arguments: ["-p",
                        "--model", AppSettings.shared.claudeModel,
                        "--output-format", "stream-json",
                        "--include-partial-messages",
                        "--verbose"]
                + ClaudeInvocation.arguments(systemPrompt: Self.systemPrompt),
            standardInput: prompt,
            environment: ToolLocator.enrichedEnvironment(),
            currentDirectory: AppPaths.supportRoot,
            timeout: 300,
            onStandardOutputLine: { line in accumulator.consume(line) })

        if let failure = accumulator.failure {
            throw ClaudeInvocation.failure(status: output.status, detail: failure)
        }

        // The final `result` event carries the complete text; the accumulated
        // deltas are the fallback if that event never arrived.
        let text = accumulator.finalText ?? accumulator.streamedText
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            let stderr = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.status != 0 {
                throw ShellError.nonZeroExit("claude", output.status, stderr)
            }
            throw ClaudeError.emptyResponse
        }

        return Answer(text: trimmed, groundedIn: built.included)
    }

    static func assemble(question: String, history: [ChatMessage], context: String,
                         userName: String? = nil) -> String {
        var parts: [String] = []
        if let userName = userName?.trimmingCharacters(in: .whitespacesAndNewlines), !userName.isEmpty {
            parts.append(SharedPrompts.Chat.userLine.replacingOccurrences(of: "{{name}}", with: userName))
        }
        parts.append("# The user's meeting library\n\n\(context)")

        // Earlier turns, so follow-ups resolve. Bounded: a long thread would
        // otherwise crowd out the meeting content, which matters more.
        // Failed and empty replies are left out: replaying an error message to
        // Claude as its own earlier answer only confuses the follow-up.
        let recent = history
            .filter { !$0.isError && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(12)
        if !recent.isEmpty {
            let turns = recent.map { message in
                let who = message.role == .user ? "User" : "You"
                return "\(who): \(message.text)"
            }
            parts.append("""
            # Conversation so far
            \(turns.joined(separator: "\n\n"))
            """)
        }

        parts.append("""
        # The user's question
        \(question)
        """)

        return parts.joined(separator: "\n\n")
    }
}

/// Parses the CLI's NDJSON stream.
///
/// Shape verified against the CLI: text arrives as
/// `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"text":…}}}`
/// and the run ends with a `result` event carrying the whole reply and an
/// `is_error` flag. Unknown event types are ignored rather than treated as
/// failures, so a future CLI adding events does not break chat.
private final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var streamed = ""
    private var final: String?
    private var errorText: String?
    private let onDelta: @Sendable (String) -> Void

    init(onDelta: @escaping @Sendable (String) -> Void) {
        self.onDelta = onDelta
    }

    var streamedText: String { lock.lock(); defer { lock.unlock() }; return streamed }
    var finalText: String? { lock.lock(); defer { lock.unlock() }; return final }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return errorText }

    func consume(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  let text = delta["text"] as? String
            else { return }
            lock.lock()
            streamed += text
            let snapshot = streamed
            lock.unlock()
            onDelta(snapshot)

        case "result":
            let isError = (json["is_error"] as? Bool) ?? false
            let result = json["result"] as? String
            lock.lock()
            if isError {
                errorText = result ?? "Claude reported an error."
            } else if let result, !result.isEmpty {
                final = result
            }
            lock.unlock()

        default:
            break
        }
    }
}
