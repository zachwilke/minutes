import Foundation
import Testing
@testable import Minutes

/// Runs against a scratch library, never the real one.
extension OnDiskLibrary {
@MainActor
@Suite(.serialized)
struct TrashTests {
    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-tests-\(UUID().uuidString)", isDirectory: true)
        AppPaths.rootOverride = root
        AppPaths.ensureDirectories()
    }

    func makeMeeting(_ store: MeetingStore) -> Meeting {
        var meeting = Meeting(title: "Weekly", startedAt: Date())
        meeting.endedAt = Date()
        meeting.state = .complete
        meeting.notes = "keep me"
        store.save(meeting)
        return meeting
    }

    @Test func trashAndRestoreKeepEverything() throws {
        let store = MeetingStore()
        let meeting = makeMeeting(store)
        try Data("audio".utf8).write(to: meeting.mixedAudioFile)

        store.moveToTrash(meeting)
        #expect(store.meeting(id: meeting.id) == nil)
        #expect(store.trashed.map(\.id) == [meeting.id])
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.path))

        store.restore(store.trashed[0])
        #expect(store.meeting(id: meeting.id)?.notes == "keep me")
        #expect(store.trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: meeting.mixedAudioFile.path))
    }

    @Test func updateDoesNotResurrectATrashedMeeting() {
        let store = MeetingStore()
        let meeting = makeMeeting(store)
        store.moveToTrash(meeting)
        #expect(store.update(id: meeting.id) { $0.notes = "late write" } == nil)
        #expect(!FileManager.default.fileExists(atPath: meeting.directory.path))
    }

    @Test func expiredTrashIsPurgedAtLaunch() throws {
        let store = MeetingStore()
        let meeting = makeMeeting(store)
        store.moveToTrash(meeting)
        let marker = AppPaths.trashRoot.appendingPathComponent(meeting.id.uuidString)
            .appendingPathComponent(".deleted-at")
        let old = Date().addingTimeInterval(-31 * 86_400)
        try ISO8601DateFormatter().string(from: old).write(to: marker, atomically: true, encoding: .utf8)

        let relaunched = MeetingStore()
        #expect(relaunched.trashed.isEmpty)
    }
}
}
