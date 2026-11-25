import Foundation
import Darwin
import Testing
@testable import Minutes

/// Launch cost of a large library: how long the store takes to load and how
/// much memory it keeps. Opt-in — it writes ~100 MB of scratch meetings — so it
/// only runs with `MINUTES_BENCH=1`:
///
///     MINUTES_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter LibraryBenchmark
extension OnDiskLibrary {
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MINUTES_BENCH"] == "1"))
struct LibraryBenchmark {
    static let meetingCount = Int(ProcessInfo.processInfo.environment["MINUTES_BENCH_COUNT"] ?? "") ?? 500

    @Test func largeLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-bench-\(UUID().uuidString)", isDirectory: true)
        AppPaths.rootOverride = root
        AppPaths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = try Self.writeLibrary(count: Self.meetingCount)
        print("BENCH library: \(Self.meetingCount) meetings, \(bytes / 1_000_000) MB of meeting.json")

        let footprintBefore = Self.footprint()
        let began = Date()
        let store = MeetingStore()
        let loadMs = Date().timeIntervalSince(began) * 1000
        let footprintAfter = Self.footprint()
        print("BENCH load: \(Int(loadMs)) ms, footprint +\((footprintAfter - footprintBefore) / 1_000_000) MB "
              + "(\(footprintAfter / 1_000_000) MB total)")

        var searchBegan = Date()
        let first = store.search("zebrafish")
        let firstSearchMs = Date().timeIntervalSince(searchBegan) * 1000
        searchBegan = Date()
        let second = store.search("zebrafis")
        let secondSearchMs = Date().timeIntervalSince(searchBegan) * 1000
        let footprintSearched = Self.footprint()
        print("BENCH search: first \(Int(firstSearchMs)) ms (\(first.count) hits), "
              + "next \(Int(secondSearchMs)) ms (\(second.count) hits), "
              + "footprint after search \(footprintSearched / 1_000_000) MB")
        #expect(first.count == Self.meetingCount / 50)
        #expect(second.count == first.count)
        withExtendedLifetime(store) {}

        // A later launch: nothing in memory, anything kept on disk is current.
        let relaunched = MeetingStore()
        searchBegan = Date()
        let afterRelaunch = relaunched.search("zebrafish")
        print("BENCH relaunch: first search \(Int(Date().timeIntervalSince(searchBegan) * 1000)) ms "
              + "(\(afterRelaunch.count) hits)")
        #expect(afterRelaunch.count == first.count)
    }

    /// Meetings shaped like an hour-long call: ~400 transcript paragraphs,
    /// notes and a summary. Every fiftieth mentions "zebrafish" in its
    /// transcript only, so search has to read transcripts to find it.
    static func writeLibrary(count: Int) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let words = ["budget", "timeline", "migration", "server", "license", "renewal", "backup",
                     "firewall", "tenant", "mailbox", "rollout", "follow", "quote", "invoice",
                     "network", "switch", "laptop", "policy", "training", "vendor"]
        var total = 0
        for index in 0..<count {
            var meeting = Meeting(title: "Meeting \(index)",
                                  startedAt: Date().addingTimeInterval(-Double(index) * 86_400))
            meeting.endedAt = meeting.startedAt.addingTimeInterval(3600)
            meeting.state = .complete
            meeting.attendees = ["Dana Lee", "Sam Ortiz"]
            meeting.notes = "Agenda: renewal and the migration plan. Follow up with Sam."
            meeting.summaryMarkdown = "## Summary\n\n" + String(repeating: "Discussed the renewal timeline. ", count: 60)
            meeting.liveTranscript = String(repeating: "rough live words ", count: 200)
            var rng = SystemRandomNumberGenerator()
            meeting.segments = (0..<400).map { n in
                var text = (0..<40).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
                if index % 50 == 0 && n == 200 { text += " zebrafish" }
                return TranscriptSegment(start: Double(n) * 9, end: Double(n) * 9 + 8,
                                         speaker: n % 2 == 0 ? .me : .others, text: text)
            }
            try FileManager.default.createDirectory(at: meeting.directory, withIntermediateDirectories: true)
            let data = try encoder.encode(meeting)
            try data.write(to: meeting.metadataFile)
            total += data.count
        }
        return total
    }

    /// The process's physical footprint — what Activity Monitor calls Memory.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
}
