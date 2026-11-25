import Foundation
import Testing
@testable import Minutes

struct ShellTests {
    /// Used to kill the whole app with SIGPIPE: the child exits, the 64 KB pipe
    /// fills, and our write lands on a closed pipe.
    @Test func childThatIgnoresItsInputDoesNotCrashUs() async throws {
        let input = String(repeating: "x", count: 2_000_000)
        let output = try await Shell.run(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                         arguments: [], standardInput: input)
        #expect(output.status == 0)
    }

    /// The deadline must run from launch, not from when stdin finished.
    @Test func timeoutAppliesToAChildThatNeverReads() async throws {
        let started = Date()
        let output = try await Shell.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                         arguments: ["30"],
                                         standardInput: String(repeating: "x", count: 1_000_000),
                                         timeout: 1)
        #expect(output.status == SIGTERM)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func cancellationKillsTheChild() async throws {
        let started = Date()
        let task = Task {
            try await Shell.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
