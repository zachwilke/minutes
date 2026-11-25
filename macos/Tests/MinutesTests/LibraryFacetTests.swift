import Foundation
import Testing
@testable import Minutes

struct LibraryFacetTests {
    @Test func companiesComeFromWorkDomainsOnly() {
        var meeting = Meeting(title: "Kickoff", startedAt: Date())
        meeting.attendeeEmails = ["dana@acme.com", "sam@Acme.com", "pat@gmail.com", "lee@globex.io", "broken"]
        #expect(meeting.companies == ["acme.com", "globex.io"])
    }

    @Test func filtersMatchTheirFacet() {
        var meeting = Meeting(title: "Kickoff", startedAt: Date())
        meeting.folder = "Acme"
        meeting.attendees = ["Dana Whitfield"]
        meeting.attendeeEmails = ["dana@acme.com"]
        #expect(LibraryFilter.folder("Acme").matches(meeting))
        #expect(!LibraryFilter.folder("Globex").matches(meeting))
        #expect(LibraryFilter.person("Dana Whitfield").matches(meeting))
        #expect(LibraryFilter.company("acme.com").matches(meeting))
    }
}
