import Foundation

/// Connects the meeting library's MCP server (`Minutes --mcp`) to the Claude
/// apps on this Mac, so either can answer "what did I agree with Marcus?" from
/// the library.
///
/// Both connections are local: each app starts this binary itself when it
/// needs it and talks to it over stdin and stdout. Nothing listens on a port,
/// and the library never leaves the Mac except as the passages Claude asks for.
enum ClaudeConnectors {
    /// The name the server appears under in Claude.
    static let serverName = "minutes"

    /// This copy of the app, so the connection follows wherever it is installed.
    static var binaryPath: String {
        Bundle.main.executableURL?.path ?? "/Applications/Minutes.app/Contents/MacOS/Minutes"
    }

    /// Where a Claude app stands with this server.
    enum Status: Equatable {
        case connected
        case notConnected
        /// Registered, but starting a different copy of the app — an old
        /// Minutes path, or a build somewhere else.
        case otherCopy(String)
        case unavailable
    }

    // MARK: - Claude Desktop

    static var desktopConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var isDesktopInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            || FileManager.default.fileExists(atPath: desktopConfigURL.deletingLastPathComponent().path)
    }

    /// Whether Claude Desktop's config already starts this server, from this path.
    static func isInDesktop() -> Bool { desktopStatus() == .connected }

    static func desktopStatus() -> Status {
        guard isDesktopInstalled else { return .unavailable }
        guard let data = try? Data(contentsOf: desktopConfigURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any] else { return .notConnected }
        let command = entry["command"] as? String ?? ""
        return command == binaryPath ? .connected : .otherCopy(command)
    }

    /// The config without this server, everything else untouched.
    static func removedDesktopConfig(_ existing: Data) throws -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
            throw ConnectorError.unreadableConfig
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = nil
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    static func removeFromDesktop() throws {
        let url = desktopConfigURL
        guard let existing = try? Data(contentsOf: url) else { return }
        let updated = try removedDesktopConfig(existing)
        try existing.write(to: url.appendingPathExtension("minutes-backup"), options: .atomic)
        try updated.write(to: url, options: .atomic)
        Log.info("Removed the Minutes MCP server from Claude Desktop")
    }

    /// The config with this server added or updated, and everything else in
    /// it — other servers, preferences — left exactly as it was.
    static func mergedDesktopConfig(_ existing: Data?, binary: String) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                throw ConnectorError.unreadableConfig
            }
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": binary, "args": ["--mcp"]]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    /// Adds the server to Claude Desktop. A copy of the previous config is
    /// kept beside it; Claude Desktop reads the file at launch, so it has to
    /// be restarted to see the new server.
    static func addToDesktop() throws {
        let url = desktopConfigURL
        let existing = try? Data(contentsOf: url)
        let merged = try mergedDesktopConfig(existing, binary: binaryPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            try existing.write(to: url.appendingPathExtension("minutes-backup"), options: .atomic)
        }
        try merged.write(to: url, options: .atomic)
        Log.info("Added the Minutes MCP server to Claude Desktop")
    }

    // MARK: - Claude Code

    /// The command, for anyone who would rather run it themselves.
    static var codeCommand: String {
        "claude mcp add --scope user \(serverName) -- \"\(binaryPath)\" --mcp"
    }

    static func isInCode() async -> Bool { await codeStatus() == .connected }

    static func codeStatus() async -> Status {
        guard let claude = ToolLocator.find("claude") else { return .unavailable }
        guard let output = try? await Shell.run(executable: claude, arguments: ["mcp", "get", serverName],
                                                environment: ToolLocator.enrichedEnvironment(), timeout: 20),
              output.status == 0 else { return .notConnected }
        if output.standardOutput.contains(binaryPath) { return .connected }
        let command = output.standardOutput.components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Command:") }
            .map { $0.replacingOccurrences(of: "Command:", with: "").trimmingCharacters(in: .whitespaces) } ?? ""
        return .otherCopy(command)
    }

    static func removeFromCode() async throws {
        guard let claude = ToolLocator.find("claude") else { throw ConnectorError.claudeMissing }
        let output = try await Shell.run(executable: claude,
                                         arguments: ["mcp", "remove", "--scope", "user", serverName],
                                         environment: ToolLocator.enrichedEnvironment(), timeout: 20)
        guard output.status == 0 else {
            throw ConnectorError.commandFailed(output.standardError.isEmpty ? output.standardOutput : output.standardError)
        }
        Log.info("Removed the Minutes MCP server from Claude Code")
    }

    // MARK: - Self-test

    /// Starts this copy's server the way Claude does and asks for its tools —
    /// proof the connection will work, without involving Claude or using any
    /// of the plan's usage.
    static func selfTest() async -> Result<[String], ConnectorError> {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"minutes-settings","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        ].joined(separator: "\n") + "\n"
        do {
            let output = try await Shell.run(executable: URL(fileURLWithPath: binaryPath), arguments: ["--mcp"],
                                             standardInput: requests, timeout: 20)
            let names = output.standardOutput.components(separatedBy: .newlines).compactMap { line -> [String]? in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["id"] as? Int == 2,
                      let tools = (object["result"] as? [String: Any])?["tools"] as? [[String: Any]] else { return nil }
                return tools.compactMap { $0["name"] as? String }
            }.first
            guard let names, !names.isEmpty else {
                return .failure(.commandFailed("The server started but listed no tools."))
            }
            return .success(names)
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }
    }

    /// Registers the server for every Claude Code session (user scope),
    /// replacing a registration that points somewhere else.
    static func addToCode() async throws {
        guard let claude = ToolLocator.find("claude") else { throw ConnectorError.claudeMissing }
        let environment = ToolLocator.enrichedEnvironment()
        _ = try? await Shell.run(executable: claude, arguments: ["mcp", "remove", "--scope", "user", serverName],
                                 environment: environment, timeout: 20)
        let output = try await Shell.run(
            executable: claude,
            arguments: ["mcp", "add", "--scope", "user", serverName, "--", binaryPath, "--mcp"],
            environment: environment, timeout: 30)
        guard output.status == 0 else {
            throw ConnectorError.commandFailed(output.standardError.isEmpty ? output.standardOutput : output.standardError)
        }
        Log.info("Added the Minutes MCP server to Claude Code")
    }

    enum ConnectorError: LocalizedError {
        case unreadableConfig
        case claudeMissing
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableConfig: return "Claude Desktop's config file isn't valid JSON, so it was left alone."
            case .claudeMissing: return "Claude Code isn't installed."
            case .commandFailed(let detail): return detail.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
