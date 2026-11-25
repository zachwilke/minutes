import Foundation

/// Finds command line tools from inside an app bundle.
///
/// A GUI app launched from Finder inherits a bare `PATH` that contains neither
/// Homebrew nor `~/.local/bin`, so `claude` and `whisper-cli` are both invisible
/// unless we go looking. We check the usual install locations first and only
/// fall back to a login shell (which is slow but honours the user's own PATH).
enum ToolLocator {
    private static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.bun/bin",
        NSHomeDirectory() + "/.claude/local",
        NSHomeDirectory() + "/bin",
        NSHomeDirectory() + "/.npm-global/bin"
    ]

    /// npm installs under nvm land in a per-version directory.
    private static var nvmDirectories: [String] {
        let root = NSHomeDirectory() + "/.nvm/versions/node"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return versions.sorted().reversed().map { "\(root)/\($0)/bin" }
    }

    private static var cache: [String: URL] = [:]
    /// Misses are remembered briefly. Settings and setup look tools up on every
    /// refresh, and on a fresh Mac — where they are missing by definition — each
    /// lookup used to pay for a login shell on the main thread.
    private static var misses: [String: Date] = [:]
    private static let missLifetime: TimeInterval = 30
    private static let lock = NSLock()

    /// Drops a cached location — needed after installing a tool at runtime,
    /// or the cache would keep reporting it missing.
    static func invalidate(_ name: String) {
        lock.lock()
        cache[name] = nil
        misses[name] = nil
        lock.unlock()
    }

    static func find(_ name: String) -> URL? {
        lock.lock()
        if let cached = cache[name] { lock.unlock(); return cached }
        if let missed = misses[name], Date().timeIntervalSince(missed) < missLifetime {
            lock.unlock()
            return nil
        }
        lock.unlock()

        var found: URL?
        for directory in searchDirectories + nvmDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                found = candidate
                break
            }
        }

        if found == nil {
            found = findViaLoginShell(name)
        }

        if let found {
            lock.lock(); cache[name] = found; lock.unlock()
            Log.info("Located \(name) at \(found.path)")
        } else {
            lock.lock(); misses[name] = Date(); lock.unlock()
            Log.warn("Could not locate \(name)")
        }
        return found
    }

    /// Last resort: ask the user's shell where the tool is.
    ///
    /// Interactive as well as login, so `.zshrc` runs — that is where nvm and
    /// most npm-global PATH changes live. Bounded, because a slow or prompting
    /// shell profile would otherwise hang whoever asked.
    private static func findViaLoginShell(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            Log.warn("Shell lookup for \(name) timed out")
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.availableData
        // An interactive profile may print a banner first; the answer is last.
        guard let path = String(data: data, encoding: .utf8)?
                .split(separator: "\n").last
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// An environment with a realistic PATH, for tools that shell out further
    /// (the Claude CLI spawns node).
    static func enrichedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"] ?? ""
        let merged = (searchDirectories + existing.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, path in
                if !result.contains(path) { result.append(path) }
            }
        environment["PATH"] = merged.joined(separator: ":")
        environment["HOME"] = NSHomeDirectory()
        return environment
    }
}
