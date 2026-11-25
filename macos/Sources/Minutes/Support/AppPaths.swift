import Foundation

/// Everything this app writes lives under one directory so the whole library is
/// easy to back up, inspect, or delete.
enum AppPaths {
    static let bundleID = "com.minutesapp.Minutes"

    /// Tests point the whole library at a scratch directory; nothing else sets it.
    nonisolated(unsafe) static var rootOverride: URL?

    static var supportRoot: URL {
        if let rootOverride { return rootOverride }
        // Under `swift test` nothing may touch the real library or its log:
        // a test that trashes or purges a meeting must only ever see scratch.
        if let testRoot { return testRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Minutes", isDirectory: true)
    }

    /// A per-process scratch root when running inside the test runner.
    private static let testRoot: URL? = {
        let process = ProcessInfo.processInfo
        let underTests = process.environment["XCTestConfigurationFilePath"] != nil
            || process.processName.contains("xctest")
            || process.processName.contains("swiftpm-testing-helper")
            || process.arguments.contains { $0.hasSuffix(".xctest") }
        guard underTests else { return nil }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-tests-\(process.processIdentifier)", isDirectory: true)
    }()

    /// One folder per meeting: audio, transcript, notes, summary.
    static var meetingsRoot: URL { supportRoot.appendingPathComponent("Meetings", isDirectory: true) }
    /// Deleted meetings, kept for 30 days so a mis-click is recoverable.
    static var trashRoot: URL { supportRoot.appendingPathComponent("Trash", isDirectory: true) }
    static var modelsRoot: URL { supportRoot.appendingPathComponent("Models", isDirectory: true) }
    static var logsRoot: URL { supportRoot.appendingPathComponent("Logs", isDirectory: true) }
    /// Derived data that is safe to delete: rebuilt on demand.
    static var cacheRoot: URL { supportRoot.appendingPathComponent("Cache", isDirectory: true) }
    /// Lowercased transcript text for search; see `TranscriptSearchText`.
    static var searchTextRoot: URL { cacheRoot.appendingPathComponent("SearchText", isDirectory: true) }
    static var settingsFile: URL { supportRoot.appendingPathComponent("settings.json") }

    static func meetingDir(_ id: UUID) -> URL {
        meetingsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func ensureDirectories() {
        migrateLegacyLibraryIfNeeded()
        for dir in [supportRoot, meetingsRoot, trashRoot, modelsRoot, logsRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The app used to be called ITEMinutes and kept its library in a folder of
    /// that name. On the first launch after the rename, move the whole folder
    /// across so meetings, models and settings come with it. Only ever a move
    /// of the old folder onto a name nothing is using: if the new folder
    /// already exists the old one is left exactly where it is, for the user to
    /// look at and delete themselves.
    private static func migrateLegacyLibraryIfNeeded() {
        guard rootOverride == nil, testRoot == nil else { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = base.appendingPathComponent("ITEMinutes", isDirectory: true)
        let current = base.appendingPathComponent("Minutes", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: current)
            Log.info("Moved the library from ITEMinutes to Minutes")
        } catch {
            Log.error("Could not move the ITEMinutes library: \(error.localizedDescription)")
        }
    }
}
