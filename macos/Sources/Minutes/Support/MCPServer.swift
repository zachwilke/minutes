import Foundation

/// A read-only Model Context Protocol server over stdio: `Minutes --mcp`.
///
/// It lets an interactive Claude Code session — or any MCP client — read the
/// meeting library directly, which the app's own headless `claude -p` runs
/// cannot do the other way round. Registered with
/// `claude mcp add minutes -- <app>/Contents/MacOS/Minutes --mcp` (or the
/// Settings buttons, which also add it to Claude Desktop), it puts
/// "what did we agree with Acme last week?" a question away.
///
/// Local and strictly read-only: it never writes to the library and opens no
/// sockets. Newline-delimited JSON-RPC 2.0, as the MCP stdio transport
/// specifies. Logging goes to stderr, never stdout.
enum MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() {
        Log.info("MCP server started")
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = handle(line: line) {
                write(response)
            }
        }
        Log.info("MCP server stopped (stdin closed)")
    }

    /// One request in, at most one response out. Notifications get none.
    static func handle(line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return error(id: NSNull(), code: -32700, message: "Parse error")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : error(id: id!, code: -32600, message: "Invalid request")
        }
        // Notifications (no id) are acknowledged by silence.
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? supportedVersions[0]
            return result(id: id, [
                "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "minutes", "version": appVersion],
                "instructions": instructions
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(id: id, callTool(name, arguments))
        default:
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// How to use the library, and whose it is. The name matters: through
    /// MCP a transcript's "You" is otherwise anonymous, and a question like
    /// "what did I promise Marcus?" needs to know who "I" is.
    static var instructions: String {
        var text = "Access to the user's Minutes meeting library: meetings recorded and transcribed "
            + "on their Mac, with their own notes and notes written afterwards. To answer a question about "
            + "what was said or decided, start with search_meetings, which returns the matching passages "
            + "with their meeting, time and speaker. Use list_meetings to browse by date, person or topic, "
            + "and get_meeting for one meeting's full notes and transcript. Transcripts come from speech "
            + "recognition, so expect errors in names and terms. Speaker labels come from which audio "
            + "source was louder, not voice identification: \"You\" is the user's microphone and \"Them\" "
            + "everyone on the call, and a quiet voice from the call is often labelled \"You\" — go by what "
            + "is said, and by who was invited, before trusting a label."
        let name = AppSettings.shared.myName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            text += " The user is \(name); \"You\" and \"I\" in their questions and transcripts mean them."
        }
        return text
    }

    // MARK: - Tools

    private static let tools: [[String: Any]] = [
        [
            "name": "search_meetings",
            "description": "Search every meeting for passages about something: the transcript, the user's "
                + "own notes and the written notes. Returns each matching passage with its meeting, date, "
                + "time in the recording and speaker, plus the lines either side, newest meetings first. "
                + "The fastest way to answer \"what did we say about X\" or \"when did Marcus mention Y\".",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string",
                              "description": "Words to find. A question works too; filler words are ignored."],
                    "since": ["type": "string", "description": "Only meetings on or after this date (YYYY-MM-DD)."],
                    "limit": ["type": "integer", "description": "Maximum passages to return (default 20, max 60)."]
                ],
                "required": ["query"]
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false,
                            "idempotentHint": true, "openWorldHint": false]
        ],
        [
            "name": "list_meetings",
            "description": "List meetings in the Minutes library, newest first, optionally "
                + "filtered by a search across titles, attendees, the user's notes, summaries and "
                + "transcripts. Returns each meeting's id, date, duration, title, attendees and "
                + "the first line of its notes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to search for. Omit to list everything."],
                    "since": ["type": "string", "description": "Only meetings on or after this date (YYYY-MM-DD)."],
                    "limit": ["type": "integer", "description": "Maximum meetings to return (default 25, max 200)."]
                ]
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ],
        [
            "name": "get_meeting",
            "description": "Get one meeting by id: its metadata, the user's own notes, the "
                + "generated notes, and (unless include_transcript is false) the full transcript.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The meeting id from list_meetings."],
                    "include_transcript": ["type": "boolean", "description": "Default true."]
                ],
                "required": ["id"]
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ]
    ]

    static func callTool(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "search_meetings":
            return text(searchMeetings(MeetingStore.loadIndex(), arguments))
        case "list_meetings":
            // The index only: a transcript is read when a query needs it, one
            // at a time, rather than the whole library's at once.
            return text(listMeetings(MeetingStore.loadIndex(), arguments))
        case "get_meeting":
            guard let raw = arguments["id"] as? String, let id = UUID(uuidString: raw) else {
                return text("Pass the meeting's id, as returned by list_meetings.", isError: true)
            }
            guard let meeting = MeetingStore.loadMeeting(id: id) else {
                return text("No meeting with id \(raw).", isError: true)
            }
            return text(render(meeting, transcript: arguments["include_transcript"] as? Bool ?? true))
        default:
            return text("Unknown tool \(name).", isError: true)
        }
    }

    static func listMeetings(_ meetings: [Meeting], _ arguments: [String: Any]) -> String {
        var matches = meetings
        if let since = (arguments["since"] as? String).flatMap(dayFormatter.date(from:)) {
            matches = matches.filter { $0.startedAt >= since }
        }
        if let query = arguments["query"] as? String,
           !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let terms = query.lowercased().split(separator: " ").map(String.init)
            matches = matches.filter { meeting in
                let haystack = [meeting.displayTitle, meeting.attendees.joined(separator: " "),
                                meeting.notes, meeting.summaryMarkdown ?? ""]
                    .joined(separator: "\n").lowercased()
                let missing = terms.filter { !haystack.contains($0) }
                guard !missing.isEmpty else { return true }
                // Only read the transcript when the rest did not settle it.
                let transcript = meeting.loadedTranscriptText().lowercased()
                return missing.allSatisfy(transcript.contains)
            }
        }
        let limit = min(max((arguments["limit"] as? Int) ?? 25, 1), 200)
        guard !matches.isEmpty else { return "No meetings match." }
        let rows = matches.prefix(limit).map { meeting -> String in
            var row = "- \(meeting.id.uuidString) · \(stampFormatter.string(from: meeting.startedAt)) · "
                + "\(meeting.durationLabel) · \(meeting.displayTitle)"
            if !meeting.attendees.isEmpty { row += " · with \(meeting.attendees.joined(separator: ", "))" }
            if let folder = meeting.folder { row += " · folder: \(folder)" }
            if let first = firstLine(meeting.summaryMarkdown ?? meeting.notes) { row += "\n  \(first)" }
            return row
        }
        let more = matches.count > limit ? "\n\n\(matches.count - limit) more not shown; raise limit or narrow the query." : ""
        return "\(matches.count) meeting\(matches.count == 1 ? "" : "s"), newest first. Times are local.\n\n"
            + rows.joined(separator: "\n") + more
    }

    // MARK: - Passage search

    /// Words that carry no meaning in a question, so "what did we decide
    /// about the VPN rollout" searches for "decide VPN rollout".
    private static let fillerWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by",
        "what", "whats", "did", "does", "do", "is", "was", "were", "are", "be", "been", "we", "i", "me", "my",
        "our", "us", "you", "they", "he", "she", "it", "that", "this", "how", "when", "who", "why", "where",
        "which", "any", "anything", "say", "said", "tell", "mention", "mentioned", "talk", "talked", "there"
    ]

    static func searchTerms(_ query: String) -> [String] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let meaningful = words.filter { !fillerWords.contains($0) }
        return Array(NSOrderedSet(array: meaningful.isEmpty ? words : meaningful)) as? [String] ?? []
    }

    /// Passages where every search term appears within a few lines of each
    /// other. Meetings whose title, notes and transcript do not contain every
    /// term are skipped without loading their transcript.
    static func searchMeetings(_ meetings: [Meeting], _ arguments: [String: Any]) -> String {
        let terms = searchTerms(arguments["query"] as? String ?? "")
        guard !terms.isEmpty else { return "Pass the words to search for." }
        let limit = min(max((arguments["limit"] as? Int) ?? 20, 1), 60)
        var candidates = meetings
        if let since = (arguments["since"] as? String).flatMap(dayFormatter.date(from:)) {
            candidates = candidates.filter { $0.startedAt >= since }
        }

        var blocks: [String] = []
        var passages = 0
        var meetingsHit = 0
        for indexed in candidates.sorted(by: { $0.startedAt > $1.startedAt }) {
            guard passages < limit else { break }
            let surface = [indexed.displayTitle, indexed.attendees.joined(separator: " "),
                           indexed.notes, indexed.summaryMarkdown ?? ""].joined(separator: "\n").lowercased()
            let transcriptText = indexed.transcriptLoaded
                ? indexed.transcriptText.lowercased()
                : (indexed.hasTranscript ? TranscriptSearchText.lowercasedText(for: indexed.id) : "")
            guard terms.allSatisfy({ surface.contains($0) || transcriptText.contains($0) }) else { continue }
            let meeting = indexed.transcriptLoaded ? indexed : (MeetingStore.loadMeeting(id: indexed.id) ?? indexed)

            var found: [String] = []
            // The user's notes and the written notes: whole lines.
            for (label, body) in [("Your notes", meeting.notes), ("Written notes", meeting.summaryMarkdown ?? "")] {
                for line in body.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, terms.allSatisfy(trimmed.lowercased().contains) else { continue }
                    found.append("  [\(label)] \(trimmed)")
                }
            }
            // The transcript: a line and its neighbours, so a term in a
            // question and one in its answer still meet.
            let segments = meeting.segments
            var index = 0
            while index < segments.count {
                let window = max(0, index - 1)...min(segments.count - 1, index + 1)
                let text = window.map { segments[$0].text }.joined(separator: " ").lowercased()
                if terms.allSatisfy(text.contains), terms.contains(where: segments[index].text.lowercased().contains) {
                    found.append(window.map { position in
                        let segment = segments[position]
                        return "  [\(segment.timestampLabel)] \(meeting.label(for: segment.speaker)): \(segment.text)"
                    }.joined(separator: "\n"))
                    index = window.upperBound + 1
                } else {
                    index += 1
                }
            }
            guard !found.isEmpty else { continue }
            let room = limit - passages
            meetingsHit += 1
            passages += min(found.count, room)
            var header = "## \(meeting.displayTitle) · \(stampFormatter.string(from: meeting.startedAt))"
            if !meeting.attendees.isEmpty { header += " · with \(meeting.attendees.joined(separator: ", "))" }
            header += " · id \(meeting.id.uuidString)"
            blocks.append(([header] + found.prefix(room)).joined(separator: "\n\n"))
        }
        guard !blocks.isEmpty else {
            return "No passages contain all of: \(terms.joined(separator: ", ")). Try fewer or different words, "
                + "or list_meetings to browse."
        }
        return "\(passages) passage\(passages == 1 ? "" : "s") from \(meetingsHit) meeting\(meetingsHit == 1 ? "" : "s"), "
            + "newest first, searching for: \(terms.joined(separator: ", ")). Times are local; [mm:ss] is the "
            + "time into the recording.\n\n" + blocks.joined(separator: "\n\n")
    }

    static func render(_ meeting: Meeting, transcript: Bool) -> String {
        var parts = ["# \(meeting.displayTitle)",
                     "- Date: \(stampFormatter.string(from: meeting.startedAt)) (local time)",
                     "- Duration: \(meeting.durationLabel)"]
        if let app = meeting.detectedAppName { parts.append("- Platform: \(app)") }
        if !meeting.attendees.isEmpty { parts.append("- Invited: \(meeting.attendees.joined(separator: ", "))") }
        if let folder = meeting.folder { parts.append("- Folder: \(folder)") }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("\n## The user's own notes\n\n\(notes)") }
        if let summary = meeting.summaryMarkdown, !summary.isEmpty {
            parts.append("\n## Generated notes\n\n\(summary)")
        }
        if transcript {
            let body = meeting.loadedTranscriptText()
            if !body.isEmpty { parts.append("\n## Transcript\n\n\(body)") }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Plumbing

    private static func text(_ body: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": body]], "isError": isError]
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func firstLine(_ text: String) -> String? {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("|") }
            .map { String($0.prefix(180)) }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
