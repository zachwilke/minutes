import Foundation
import Testing
@testable import Minutes

/// The library index keeps transcripts on disk. These check that nothing that
/// needs a transcript goes without, and that no save ever writes an empty one
/// over the real thing.
extension OnDiskLibrary {
@MainActor
@Suite(.serialized)
struct LazyTranscriptTests {
    init() {
        AppPaths.rootOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("minutes-tests-\(UUID().uuidString)", isDirectory: true)
        AppPaths.ensureDirectories()
    }

    /// Saves a finished meeting with a transcript and returns its id.
    @discardableResult
    func saveMeeting(_ store: MeetingStore, title: String = "Acme renewal",
                     transcript: String = "we agreed the zebrafish budget",
                     live: String = "rough words") -> UUID {
        var meeting = Meeting(title: title, startedAt: Date())
        meeting.endedAt = Date().addingTimeInterval(600)
        meeting.state = .complete
        meeting.notes = "my notes"
        meeting.liveTranscript = live
        meeting.segments = [TranscriptSegment(start: 0, end: 5, speaker: .me, text: "Hello there."),
                            TranscriptSegment(start: 5, end: 9, speaker: .others, text: transcript)]
        store.save(meeting)
        return meeting.id
    }

    func onDisk(_ id: UUID) throws -> Meeting {
        try #require(MeetingStore.loadMeeting(id: id))
    }

    @Test func theIndexLoadsWithoutTranscripts() throws {
        let id = saveMeeting(MeetingStore())

        let relaunched = MeetingStore()
        let indexed = try #require(relaunched.meeting(id: id))
        #expect(!indexed.transcriptLoaded)
        #expect(indexed.segments.isEmpty)
        #expect(indexed.liveTranscript.isEmpty)
        #expect(indexed.hasSegments)
        #expect(indexed.hasTranscript)
        #expect(indexed.notes == "my notes")
        #expect(!relaunched.isTranscriptCached(id))

        let full = try #require(relaunched.fullMeeting(id: id))
        #expect(full.transcriptLoaded)
        #expect(full.segments.count == 2)
        #expect(full.liveTranscript == "rough words")
        #expect(relaunched.isTranscriptCached(id))
        // The index itself stays light after opening a meeting.
        #expect(relaunched.meeting(id: id)?.transcriptLoaded == false)
    }

    @Test func savingAnIndexCopyKeepsTheTranscript() throws {
        let id = saveMeeting(MeetingStore())
        let relaunched = MeetingStore()

        // The sidebar files a meeting from its index copy.
        var indexed = try #require(relaunched.meeting(id: id))
        indexed.folder = "Clients"
        relaunched.save(indexed)
        #expect(try onDisk(id).folder == "Clients")
        #expect(try onDisk(id).segments.count == 2)
        #expect(try onDisk(id).liveTranscript == "rough words")

        // A relaunch, so nothing is cached, then update().
        let again = MeetingStore()
        #expect(!again.isTranscriptCached(id))
        again.update(id: id) { $0.title = "Renamed" }
        #expect(try onDisk(id).title == "Renamed")
        #expect(try onDisk(id).segments.count == 2)
    }

    @Test func aTranscriptFieldSetOnAnIndexCopyIsSaved() throws {
        let id = saveMeeting(MeetingStore(), live: "")
        let relaunched = MeetingStore()
        var indexed = try #require(relaunched.meeting(id: id))
        indexed.liveTranscript = "final live text"
        relaunched.save(indexed)
        #expect(try onDisk(id).liveTranscript == "final live text")
        #expect(try onDisk(id).segments.count == 2)
    }

    @Test func updateSeesAndChangesTheTranscript() throws {
        let id = saveMeeting(MeetingStore())
        let relaunched = MeetingStore()
        var seen = 0
        relaunched.update(id: id) {
            seen = $0.segments.count
            $0.segments.append(TranscriptSegment(start: 9, end: 12, speaker: .me, text: "Bye."))
        }
        #expect(seen == 2)
        #expect(try onDisk(id).segments.count == 3)
        #expect(relaunched.meeting(id: id)?.hasSegments == true)
        #expect(relaunched.meeting(id: id)?.indexedSegmentCount == 3)
    }

    @Test func anIndexCopyCannotBeEncoded() throws {
        let id = saveMeeting(MeetingStore())
        let indexed = try #require(MeetingStore().meeting(id: id))
        #expect(throws: EncodingError.self) { try JSONEncoder().encode(indexed) }
    }

    @Test func onlyAFewTranscriptsStayInMemory() {
        let store = MeetingStore()
        let ids = (0..<12).map { saveMeeting(store, title: "Meeting \($0)") }
        let relaunched = MeetingStore()
        for id in ids { _ = relaunched.fullMeeting(id: id) }
        let cached = ids.filter(relaunched.isTranscriptCached)
        #expect(cached.count == MeetingStore.transcriptCacheLimit)
        // The most recently opened are the ones kept.
        #expect(cached == Array(ids.suffix(MeetingStore.transcriptCacheLimit)))
    }

    @Test func searchFindsTranscriptsWithoutKeepingThemResident() throws {
        let store = MeetingStore()
        let match = saveMeeting(store, title: "One", transcript: "the Zebrafish tank")
        let other = saveMeeting(store, title: "Two", transcript: "nothing of note")

        let relaunched = MeetingStore()
        #expect(relaunched.search("zebrafish").map(\.id) == [match])
        #expect(relaunched.search("ZEBRA").map(\.id) == [match])
        #expect(relaunched.search("my notes").count == 2)
        #expect(relaunched.search("no such words").isEmpty)
        #expect(relaunched.search("  ").count == 2)
        #expect(!relaunched.isTranscriptCached(match))
        #expect(!relaunched.isTranscriptCached(other))
        #expect(TranscriptSearchText.isFresh(match))
    }

    @Test func searchFollowsTranscriptEdits() {
        let store = MeetingStore()
        let id = saveMeeting(store, transcript: "the zebrafish tank")
        #expect(store.search("zebrafish").map(\.id) == [id])

        store.update(id: id) { $0.segments[1].text = "the axolotl tank" }
        #expect(store.search("zebrafish").isEmpty)
        #expect(store.search("axolotl").map(\.id) == [id])

        // Speaker names are part of the transcript text.
        store.update(id: id) { $0.speakerNames = ["others": "Priya"] }
        #expect(store.search("priya: the axolotl").map(\.id) == [id])
    }

    /// The Windows app on a shared library, or an older build, rewrites
    /// meeting.json behind the search text's back.
    @Test func searchTextFromAnOlderMeetingFileIsRebuilt() throws {
        let id = saveMeeting(MeetingStore(), transcript: "the zebrafish tank")
        #expect(MeetingStore().search("zebrafish").map(\.id) == [id])

        var edited = try onDisk(id)
        edited.segments[1].text = "the axolotl tank"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(edited).write(to: edited.metadataFile)
        // A later modification date than the search text was stamped with.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: edited.metadataFile.path)

        let relaunched = MeetingStore()
        #expect(relaunched.search("zebrafish").isEmpty)
        #expect(relaunched.search("axolotl").map(\.id) == [id])
    }

    @Test func deletingAMeetingRemovesItsSearchText() {
        let store = MeetingStore()
        let id = saveMeeting(store)
        _ = store.search("zebrafish")
        #expect(FileManager.default.fileExists(atPath: TranscriptSearchText.file(for: id).path))
        store.delete(store.meeting(id: id)!)
        #expect(!FileManager.default.fileExists(atPath: TranscriptSearchText.file(for: id).path))
    }

    @Test func trashAndRestoreKeepTheTranscript() throws {
        let id = saveMeeting(MeetingStore())
        let store = MeetingStore()
        store.moveToTrash(store.meeting(id: id)!)
        #expect(store.search("zebrafish").isEmpty)
        store.restore(store.trashed[0])
        #expect(store.fullMeeting(id: id)?.segments.count == 2)
        #expect(store.search("zebrafish").map(\.id) == [id])
    }

    @Test func prewarmBuildsSearchTextInTheBackground() async throws {
        let id = saveMeeting(MeetingStore())
        try? FileManager.default.removeItem(at: AppPaths.searchTextRoot)
        MeetingStore().prewarmSearchText()
        for _ in 0..<100 where !TranscriptSearchText.isFresh(id) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(TranscriptSearchText.isFresh(id))
    }

    @Test func mcpReadsTranscriptsFromDisk() {
        let match = saveMeeting(MeetingStore(), title: "Acme", transcript: "the zebrafish budget")
        saveMeeting(MeetingStore(), title: "Other", transcript: "nothing")

        let listed = MCPServer.callTool("list_meetings", ["query": "acme zebrafish"])
        let listing = ((listed["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(listing.contains(match.uuidString))
        #expect(listing.hasPrefix("1 meeting"))

        let got = MCPServer.callTool("get_meeting", ["id": match.uuidString])
        let body = ((got["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(body.contains("## Transcript"))
        #expect(body.contains("the zebrafish budget"))
    }

    @Test func askReadsTranscriptsOfIndexCopies() {
        let store = MeetingStore()
        let focus = saveMeeting(store, title: "Focus", transcript: "the zebrafish budget")
        saveMeeting(store, title: "Ranked", transcript: "talked about axolotl pricing")
        let relaunched = MeetingStore()
        #expect(relaunched.meetings.allSatisfy { !$0.transcriptLoaded })

        let focused = MeetingContextBuilder.build(question: "what happened?", history: [],
                                                  meetings: relaunched.meetings, focus: focus)
        #expect(focused.context.contains("the zebrafish budget"))

        let ranked = MeetingContextBuilder.build(question: "axolotl pricing", history: [],
                                                 meetings: relaunched.meetings)
        #expect(ranked.context.contains("talked about axolotl pricing"))
        // Ranked by the transcript: the axolotl meeting's text comes first.
        let axolotl = ranked.context.range(of: "axolotl pricing")!.lowerBound
        let zebrafish = ranked.context.range(of: "zebrafish budget")!.lowerBound
        #expect(axolotl < zebrafish)
    }

    @Test func interruptedRecordingWithOnlyATranscriptIsKept() throws {
        let store = MeetingStore()
        let id = saveMeeting(store)
        store.update(id: id) { $0.state = .recording; $0.endedAt = nil; $0.notes = "" }

        // No audio was captured, but the transcript is the user's: keep it.
        let relaunched = MeetingStore()
        #expect(relaunched.meeting(id: id)?.state == .failed)
        #expect(try onDisk(id).segments.count == 2)
    }
}
}
