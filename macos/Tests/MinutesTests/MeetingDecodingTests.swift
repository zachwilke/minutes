import Foundation
import Testing
@testable import Minutes

/// shared/spec/meeting-format.md makes everything optional except id, title and
/// startedAt. A file that fails to decode silently vanishes from the library.
struct MeetingDecodingTests {
    func decode(_ json: String) throws -> Meeting {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Meeting.self, from: Data(json.utf8))
    }

    @Test func minimalFileLoads() throws {
        let meeting = try decode("""
        {"id":"9C3A1FC0-A548-4688-824F-FECD1E5A70F1","title":"Call","startedAt":"2026-10-01T15:00:00Z"}
        """)
        #expect(meeting.notes.isEmpty)
        #expect(meeting.segments.isEmpty)
        #expect(meeting.templateID == SummaryTemplate.general.id)
    }

    @Test func unknownValuesFromANewerBuildDegrade() throws {
        let meeting = try decode("""
        {"id":"9C3A1FC0-A548-4688-824F-FECD1E5A70F1","title":"Call","startedAt":"2026-10-01T15:00:00Z",
         "state":"queued","segments":[{"start":1,"end":2,"speaker":"guest-3","text":"hi"}]}
        """)
        #expect(meeting.state == .failed)
        #expect(meeting.segments.first?.speaker == .unknown)
    }

    @Test func roundTripKeepsEveryField() throws {
        var original = Meeting(title: "Weekly", startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        original.notes = "my notes"
        original.attendees = ["A", "B"]
        original.state = .complete
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(original), as: UTF8.self)
        let decoded = try decode(json)
        #expect(decoded.id == original.id)
        #expect(decoded.notes == "my notes")
        #expect(decoded.attendees == ["A", "B"])
        #expect(decoded.state == .complete)
    }
}

struct UnknownFieldTests {
    @Test func unknownFieldsSurviveASave() throws {
        let json = """
        {"id":"9C3A1FC0-A548-4688-824F-FECD1E5A70F1","title":"Call","startedAt":"2026-10-01T15:00:00Z",
         "folderID":"F1","speakerNames":{"them":"Dana"},"flags":[1,true,null]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))
        #expect(meeting.unknownFields["folderID"] == .string("F1"))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try JSONSerialization.jsonObject(with: try encoder.encode(meeting)) as? [String: Any]
        #expect(again?["folderID"] as? String == "F1")
        #expect((again?["speakerNames"] as? [String: String])?["them"] == "Dana")
        #expect((again?["flags"] as? [Any])?.count == 3)
        #expect(again?["summaryEditedAt"] == nil)   // absent stays absent
    }
}
