import Foundation
import Testing
@testable import Minutes

/// The MCP server's passage search, and connecting it to Claude Desktop.
struct AskFromClaudeTests {

    // MARK: - Search

    @Test func questionsBecomeSearchTerms() {
        #expect(MCPServer.searchTerms("What did we say about the VPN groups?") == ["vpn", "groups"])
        #expect(MCPServer.searchTerms("ThreatLocker ThreatLocker") == ["threatlocker"])
        // All filler still searches for something rather than nothing.
        #expect(MCPServer.searchTerms("what did we say") == ["what", "did", "we", "say"])
    }

    private var library: [Meeting] {
        var vpn = Meeting(title: "Marcus Vale", startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        vpn.attendees = ["Marcus Vale"]
        vpn.segments = [
            TranscriptSegment(start: 250, end: 255, speaker: .me, text: "How are the groups set up?"),
            TranscriptSegment(start: 258, end: 270, speaker: .others, text: "The VPN has four groups under it."),
            TranscriptSegment(start: 272, end: 276, speaker: .me, text: "Great, push it next week."),
            TranscriptSegment(start: 400, end: 405, speaker: .others, text: "Unrelated talk about lunch.")
        ]
        vpn.summaryMarkdown = "## Decisions\n- Move the four VPN groups to the new policy."
        let other = Meeting(title: "Budget", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        return [other, vpn]
    }

    @Test func passagesCarryMeetingTimeAndSpeaker() {
        let result = MCPServer.searchMeetings(library, ["query": "VPN groups"])
        #expect(result.contains("## Marcus Vale"))
        #expect(result.contains("with Marcus Vale"))
        #expect(result.contains("[Written notes] - Move the four VPN groups to the new policy."))
        #expect(result.contains("[04:18] Them: The VPN has four groups under it."))
        // The question before it comes along for context; the lunch talk does not.
        #expect(result.contains("[04:10] You: How are the groups set up?"))
        #expect(!result.contains("lunch"))
        #expect(!result.contains("## Budget"))
    }

    @Test func noMatchSaysWhatWasSearched() {
        #expect(MCPServer.searchMeetings(library, ["query": "firewall renewal"])
                    .hasPrefix("No passages contain all of: firewall, renewal."))
    }

    @Test func theServerKnowsWhoTheUserIs() {
        #expect(MCPServer.instructions.contains("start with search_meetings"))
    }

    // MARK: - Claude Desktop

    @Test func addingToClaudeDesktopKeepsEverythingElse() throws {
        let existing = """
        {"mcpServers": {"rea": {"command": "/usr/local/bin/rea", "args": ["serve"]}},
         "globalShortcut": "Cmd+Shift+Space"}
        """.data(using: .utf8)!
        let merged = try ClaudeConnectors.mergedDesktopConfig(existing, binary: "/Applications/Minutes.app/Contents/MacOS/Minutes")
        let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect((servers["rea"] as? [String: Any])?["command"] as? String == "/usr/local/bin/rea")
        let minutes = try #require(servers["minutes"] as? [String: Any])
        #expect(minutes["command"] as? String == "/Applications/Minutes.app/Contents/MacOS/Minutes")
        #expect(minutes["args"] as? [String] == ["--mcp"])
        #expect(root["globalShortcut"] as? String == "Cmd+Shift+Space")
    }

    @Test func disconnectingRemovesOnlyMinutes() throws {
        let existing = Data(#"{"mcpServers": {"rea": {"command": "/r"}, "minutes": {"command": "/m", "args": ["--mcp"]}}, "theme": "dark"}"#.utf8)
        let updated = try ClaudeConnectors.removedDesktopConfig(existing)
        let root = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["minutes"] == nil)
        #expect(servers["rea"] != nil)
        #expect(root["theme"] as? String == "dark")
    }

    @Test func aMissingConfigIsCreated() throws {
        let merged = try ClaudeConnectors.mergedDesktopConfig(nil, binary: "/x/Minutes")
        let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        #expect(((root["mcpServers"] as? [String: Any])?["minutes"] as? [String: Any])?["command"] as? String == "/x/Minutes")
    }

    @Test func aBrokenConfigIsLeftAlone() {
        #expect(throws: ClaudeConnectors.ConnectorError.self) {
            try ClaudeConnectors.mergedDesktopConfig(Data("{not json".utf8), binary: "/x")
        }
    }
}
