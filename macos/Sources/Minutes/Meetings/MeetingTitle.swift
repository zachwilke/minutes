import Foundation

/// Rules for a meeting's name: cleaning one out of a call window's title, and
/// telling a real name from a placeholder that should be replaced.
///
/// Pure string handling, kept apart from the Accessibility and Claude calls
/// that feed it, so every rule here is covered by tests.
enum MeetingTitle {

    // MARK: - Window titles

    /// The meeting's name inside a conferencing app's window title, or nil
    /// when the title is only the app's own chrome.
    ///
    /// New Teams titles a meeting window "<name> | <your organisation> |
    /// <your account email>", where classic Teams used "<name> | Microsoft
    /// Teams". Both trailers are the app talking about itself, not the
    /// meeting, so both go: the account email, the organisation before it,
    /// and any segment that only names the product. A pre-join lobby —
    /// "Meeting join | Microsoft Teams meeting | …" — is chrome all the way
    /// through and names nothing.
    static func fromWindow(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Microsoft Teams", " - Webex", " - Zoom"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }

        var segments = title.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // "<name> | <organisation> | <email>": the email, then the tenant.
        if let last = segments.last, isEmailAddress(last) {
            segments.removeLast()
            if segments.count >= 2 { segments.removeLast() }
        }
        segments.removeAll { chromeSegments.contains($0.lowercased()) }
        guard !segments.isEmpty else { return nil }

        var name = segments.joined(separator: " | ")
        // An ad-hoc Teams call: "Teams call with Dana" → "Call with Dana".
        for prefix in ["Microsoft Teams call with ", "Teams call with "]
        where name.lowercased().hasPrefix(prefix.lowercased()) {
            name = "Call with " + name.dropFirst(prefix.count)
        }
        return name
    }

    /// Segments that name the app, never the meeting.
    private static let chromeSegments: Set<String> = [
        "microsoft teams", "microsoft teams (work or school)", "microsoft teams meeting",
        "microsoft teams classic", "teams meeting", "meeting join", "join meeting",
        "webex", "webex meetings", "zoom", "zoom meeting", "zoom workplace"
    ]

    private static func isEmailAddress(_ text: String) -> Bool {
        text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    // MARK: - Placeholders

    /// True for a name nobody chose: the "Meeting at 9:32 AM" or
    /// "Microsoft Teams call, 13:51" given to a recording at the start, an
    /// empty title, or "Call with <person>" — which says who, but not what.
    /// These are replaced by a title written from the meeting itself.
    static func isPlaceholder(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "meeting" || trimmed.lowercased() == "untitled meeting" {
            return true
        }
        // A clock in any locale's form: 09:32, 9:32 AM, 21.32, 9:32 p.m. The
        // narrow no-break space is what macOS puts before AM and PM.
        let clock = #"[0-9]{1,2}[:.][0-9]{2}(?:[\s\x{202F}]?[AaPp]\.?\s?[Mm]\.?)?"#
        let patterns = [
            #"^Meeting at "# + clock + "$",
            #"^.{1,60} call, "# + clock + "$",
            #"^Call with [^|]{1,80}$"#
        ]
        return patterns.contains { trimmed.range(of: $0, options: .regularExpression) != nil }
    }

    /// Whether the summary should also name this meeting. Never over the
    /// user's choice, the calendar's, or a real call window's name — only a
    /// placeholder is replaced.
    static func needsGeneratedTitle(_ meeting: Meeting) -> Bool {
        (meeting.calendarEventTitle ?? "").isEmpty && isPlaceholder(meeting.title)
    }

    /// The person in a "Call with <person>" title.
    static func callee(in title: String) -> String? {
        let prefix = "Call with "
        guard title.hasPrefix(prefix) else { return nil }
        let name = title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - Generated titles

    /// Turns a model's reply into a title, or nil when nothing usable came
    /// back. The prompt asks for the title alone; this enforces it, because a
    /// title with a "Title:" label or quotation marks in a list of meetings
    /// looks broken.
    static func sanitize(_ reply: String) -> String? {
        guard var line = reply.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        line = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^(?i:title)\s*:\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: "**", with: "")
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`")
        line = line.trimmingCharacters(in: quotes.union(.whitespaces))
        while let last = line.last, ".;:,".contains(last) { line.removeLast() }
        line = line.trimmingCharacters(in: quotes.union(.whitespaces))
        guard line.count >= 3 else { return nil }
        // Asked for 3 to 8 words; a sentence back means the model explained
        // instead of answering, and a placeholder is better than that in a list.
        guard line.split(separator: " ").count <= 12 else { return nil }
        if line.count > 80 {
            let cut = line.prefix(80)
            line = String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)])
        }
        return line
    }
}
