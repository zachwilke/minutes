import Foundation
import os

/// Dual-destination logging: unified log for `log stream`, plus a plain text file
/// under Logs/ because chasing a recording bug in Console.app is miserable.
enum Log {
    private static let logger = Logger(subsystem: AppPaths.bundleID, category: "app")
    private static let queue = DispatchQueue(label: "com.minutesapp.Minutes.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { emit("INFO", message); logger.info("\(message, privacy: .public)") }
    static func warn(_ message: String) { emit("WARN", message); logger.warning("\(message, privacy: .public)") }
    static func error(_ message: String) { emit("ERROR", message); logger.error("\(message, privacy: .public)") }

    /// Kept open for the process lifetime. Opening, seeking and closing the file
    /// for every line — plus re-checking the directory tree each time — was pure
    /// per-line overhead. Only touched on `queue`, so no extra locking.
    private static var fileHandle: FileHandle?

    /// Under `swift test` nothing reaches the log file. Tests that drive the
    /// detector and the store used to write "Meeting detected: Zoom" bursts
    /// into the real log, which then read like calls that never happened.
    private static let isTestRun: Bool = {
        let name = ProcessInfo.processInfo.processName.lowercased()
        return name.contains("xctest") || name.contains("swiftpm-testing")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    private static func emit(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(level) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard !isTestRun else { return }
        queue.async {
            let data = Data(line.utf8)
            if let handle = fileHandle {
                do {
                    try handle.write(contentsOf: data)
                    return
                } catch {
                    // Rotated or deleted underneath us; reopen below.
                    try? handle.close()
                    fileHandle = nil
                }
            }
            AppPaths.ensureDirectories()
            let url = AppPaths.logsRoot.appendingPathComponent("minutes.log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            fileHandle = handle
        }
    }
}
