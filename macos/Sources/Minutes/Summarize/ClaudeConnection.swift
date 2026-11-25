import Foundation
import Combine

/// Reports whether summarization will actually work.
///
/// Checking that the `claude` binary exists says very little — it can be present
/// and signed out, or signed in to an account without model access. The CLI
/// exposes `claude auth status`, which returns the account state as JSON and
/// costs nothing, so that carries the routine check. A round trip through the
/// model is offered separately, behind a button, because it spends the user's own
/// subscription quota and should be their choice rather than a side effect of
/// opening Settings.
@MainActor
final class ClaudeConnection: ObservableObject {
    nonisolated struct Account: Equatable {
        var email: String?
        var organization: String?
        var subscription: String?
        var authMethod: String?

        /// "Example Corp · team" — the useful part, without repeating the email.
        var summary: String {
            [organization, subscription].compactMap { $0 }.joined(separator: " · ")
        }
    }

    enum State: Equatable {
        case unknown
        case checking
        /// Binary missing entirely.
        case notFound
        /// Present but nobody is signed in.
        case signedOut
        /// Signed in. Not yet proven to answer.
        case signedIn(Account)
        /// Signed in and a prompt came back.
        case verified(Account, latency: TimeInterval)
        case failed(String)
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var cliPath: String?
    @Published private(set) var version: String?

    private static let checkTimeout: TimeInterval = 20
    private static let verifyTimeout: TimeInterval = 90

    /// Cheap and token-free: locate the binary, read its version, read auth state.
    func refresh() async {
        state = .checking

        guard let binary = ToolLocator.find("claude") else {
            cliPath = nil
            state = .notFound
            return
        }
        cliPath = binary.path

        version = await firstLine(of: binary, arguments: ["--version"])

        do {
            let output = try await Shell.run(executable: binary,
                                           arguments: ["auth", "status"],
                                           environment: ToolLocator.enrichedEnvironment(),
                                           currentDirectory: AppPaths.supportRoot,
                                           timeout: Self.checkTimeout)
            guard let account = Self.parseAuthStatus(output.standardOutput) else {
                // Non-zero exit or unparseable output almost always means the
                // CLI could not reach an account at all.
                state = output.standardOutput.contains("loggedIn") ? .signedOut : .failed(
                    output.standardError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Could not read authentication status from the claude CLI."
                        : String(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
                return
            }
            state = account.loggedIn ? .signedIn(account.account) : .signedOut
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Sends a minimal prompt so the model itself is proven to answer, and times
    /// it. Uses the model the app is configured to summarize with, so a model the
    /// account cannot reach surfaces here rather than at the end of a meeting.
    func verify() async {
        guard let path = cliPath else {
            await refresh()
            return
        }
        let previous = state
        state = .checking

        let started = Date()
        do {
            let output = try await Shell.run(
                executable: URL(fileURLWithPath: path),
                arguments: ["-p",
                            "--model", AppSettings.shared.claudeModel,
                            "--output-format", "text"]
                    // The same flags the app's real runs use, so a pass here
                    // means summaries will work.
                    + ClaudeInvocation.arguments(systemPrompt: ClaudeInvocation.plainSystemPrompt),
                standardInput: "Reply with exactly: OK",
                environment: ToolLocator.enrichedEnvironment(),
                currentDirectory: AppPaths.supportRoot,
                timeout: Self.verifyTimeout)

            let latency = Date().timeIntervalSince(started)
            let reply = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

            guard output.status == 0, !reply.isEmpty else {
                let stderr = output.standardError.lowercased()
                if stderr.contains("auth") || stderr.contains("login") || stderr.contains("expired") {
                    state = .signedOut
                } else {
                    state = .failed(Self.tidy(output.standardError, fallback:
                        "Claude exited with status \(output.status) and returned nothing."))
                }
                return
            }

            if case .signedIn(let account) = previous {
                state = .verified(account, latency: latency)
            } else {
                state = .verified(Account(), latency: latency)
            }
            Log.info("Claude round trip succeeded in \(String(format: "%.1f", latency))s")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Parsing

    nonisolated struct AuthStatus {
        var loggedIn: Bool
        var account: Account
    }

    /// `claude auth status` prints JSON. Parsed defensively: a future CLI could
    /// change the shape, and that should degrade to "unknown", not crash.
    nonisolated static func parseAuthStatus(_ output: String) -> AuthStatus? {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let account = Account(email: json["email"] as? String,
                              organization: json["orgName"] as? String,
                              subscription: json["subscriptionType"] as? String,
                              authMethod: json["authMethod"] as? String)
        return AuthStatus(loggedIn: (json["loggedIn"] as? Bool) ?? false, account: account)
    }

    private func firstLine(of binary: URL, arguments: [String]) async -> String? {
        do {
            let output = try await Shell.run(executable: binary,
                                            arguments: arguments,
                                            environment: ToolLocator.enrichedEnvironment(),
                                            timeout: 15)
            return output.standardOutput
                .split(separator: "\n")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func tidy(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.suffix(240))
    }
}
