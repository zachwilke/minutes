import Foundation
import Testing
@testable import Minutes

struct MCPServerTests {
    @Test func initializeNegotiatesAVersionAndOffersTools() throws {
        let response = try #require(MCPServer.handle(line: """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}
        """))
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test func notificationsGetNoResponse() {
        #expect(MCPServer.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func unknownMethodsAndGarbageAreErrors() {
        let unknown = MCPServer.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        #expect((unknown?["error"] as? [String: Any])?["code"] as? Int == -32601)
        let garbage = MCPServer.handle(line: "not json")
        #expect((garbage?["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func listingFiltersByEveryTerm() {
        var acme = Meeting(title: "Acme renewal", startedAt: Date())
        acme.notes = "SSO before renewal"
        let other = Meeting(title: "Standup", startedAt: Date())
        let text = MCPServer.listMeetings([acme, other], ["query": "acme sso"])
        #expect(text.contains(acme.id.uuidString))
        #expect(!text.contains(other.id.uuidString))
    }
}
