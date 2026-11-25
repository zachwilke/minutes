import Foundation

/// Chooses what Claude sees when answering a question about the library.
///
/// A whole library cannot go into one prompt — a year of meetings is millions of
/// characters. But naive retrieval is worse than it looks: if only the top few
/// matches are sent, Claude cannot answer "when did I last speak to Dana?" or
/// "how many times has this come up?", because it has no idea what else exists.
///
/// So the context is layered. Every meeting always appears in a compact index —
/// date, title, duration, attendees, one line of summary — which is cheap and
/// makes the shape of the library known. Full summaries are then added in
/// relevance order until a character budget runs out, and transcripts after that
/// if room remains. Anything that did not fit is stated explicitly, so a partial
/// answer can be reported as partial rather than presented as complete.
struct MeetingContextBuilder {
    /// About 20,000 tokens. It was 240,000 characters — 60,000 tokens on every
    /// question, and again on every follow-up, since each runs fresh. The
    /// index of every meeting always goes in, then your notes on the most
    /// relevant ones, and transcripts only with room left; past that point
    /// more transcript buys little answer for a lot of usage.
    static let budget = 80_000

    struct Result {
        var context: String
        /// Meetings whose full text was included, most relevant first.
        var included: [UUID]
        var indexedCount: Int
        var truncated: Bool
    }

    // Generated from shared/prompts/chat.json.
    static let indexNote = SharedPrompts.Chat.indexNote
    static let coverageNote = SharedPrompts.Chat.coverageNote

    /// `focus` is the meeting a question is asked from inside of. Its notes and
    /// transcript always come first, in full, ahead of anything ranked.
    static func build(question: String, history: [ChatMessage], meetings: [Meeting],
                      focus: UUID? = nil) -> Result {
        guard !meetings.isEmpty else {
            return Result(context: "The meeting library is empty.",
                          included: [], indexedCount: 0, truncated: false)
        }

        let terms = searchTerms(in: question, history: history)
        let ranked = meetings
            .map { (meeting: $0, score: relevance(of: $0, terms: terms)) }
            .sorted {
                // Ties break to the more recent meeting, which is almost always
                // what someone means by "the" meeting about something.
                $0.score == $1.score ? $0.meeting.startedAt > $1.meeting.startedAt
                                     : $0.score > $1.score
            }

        var sections: [String] = []
        var used = 0
        var included: [UUID] = []
        var truncated = false

        let index = indexSection(meetings)
        sections.append(index)
        used += index.count

        // The meeting being asked about, before anything competes for budget.
        let focused = focus.flatMap { id in meetings.first { $0.id == id } }
        if let focused {
            var blocks: [String] = []
            if let body = notesBody(focused) {
                blocks.append(detailBlock(focused, body: body.text, label: body.label))
            }
            let transcript = focused.loadedTranscriptText()
            if !transcript.isEmpty {
                blocks.append(detailBlock(focused, body: transcript, label: "Transcript"))
            }
            let section = "## The meeting this question is about\n\n" + blocks.joined(separator: "\n\n")
            if !blocks.isEmpty, used + section.count <= budget {
                sections.append(section)
                included.append(focused.id)
                used += section.count
            }
        }
        let others = ranked.filter { $0.meeting.id != focused?.id }

        // Full summaries, most relevant first. A meeting without one — never
        // summarized, or summarizing failed — contributes the user's own notes,
        // which would otherwise be invisible here. A block that does not fit is
        // skipped, not the end of the loop: one huge entry near the top must not
        // starve every smaller one after it.
        var summaries: [String] = []
        for entry in others {
            guard let body = notesBody(entry.meeting) else { continue }
            let block = detailBlock(entry.meeting, body: body.text, label: body.label)
            if used + block.count > budget { truncated = true; continue }
            summaries.append(block)
            included.append(entry.meeting.id)
            used += block.count
        }
        if !summaries.isEmpty {
            sections.append("## Notes from these meetings\n\n" + summaries.joined(separator: "\n\n"))
        }

        // Transcripts only once every summary fits — the summaries are the more
        // useful text per character, so they get the budget first.
        if !truncated {
            var transcripts: [String] = []
            for entry in others where entry.meeting.hasTranscript {
                // Read one at a time and let go: an index copy's transcript
                // comes from disk, and only those that fit stay in the prompt.
                let transcript = entry.meeting.loadedTranscriptText()
                guard !transcript.isEmpty else { continue }
                let block = detailBlock(entry.meeting, body: transcript, label: "Transcript")
                if used + block.count > budget { truncated = true; continue }
                transcripts.append(block)
                if !included.contains(entry.meeting.id) { included.append(entry.meeting.id) }
                used += block.count
            }
            if !transcripts.isEmpty {
                sections.append("## Full transcripts\n\n" + transcripts.joined(separator: "\n\n"))
            }
        }

        if truncated {
            sections.append("""
            ## Coverage
            \(Self.coverageNote)
            """)
        }

        return Result(context: sections.joined(separator: "\n\n"),
                      included: included,
                      indexedCount: meetings.count,
                      truncated: truncated)
    }

    // MARK: - Sections

    /// Every meeting, compactly. This is what lets Claude count, compare dates,
    /// and notice a meeting whose detail was not included.
    private static func indexSection(_ meetings: [Meeting]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        let rows = meetings
            .sorted { $0.startedAt > $1.startedAt }
            .map { meeting -> String in
                var row = "- \(formatter.string(from: meeting.startedAt)) · \(meeting.durationLabel) · \(meeting.displayTitle)"
                if let app = meeting.detectedAppName { row += " · \(app)" }
                if !meeting.attendees.isEmpty {
                    row += " · invited: \(meeting.attendees.joined(separator: ", "))"
                }
                if let first = firstLine(of: meeting.summaryMarkdown) {
                    row += "\n    \(first)"
                } else if meeting.state == .failed {
                    row += "\n    (not transcribed: \(meeting.failureReason ?? "unknown"))"
                }
                return row
            }

        return """
        ## Every meeting in the library (\(meetings.count))
        \(indexNote)

        \(rows.joined(separator: "\n"))
        """
    }

    /// The best prose for a meeting: its summary, else the user's own notes.
    private static func notesBody(_ meeting: Meeting) -> (text: String, label: String)? {
        if let summary = meeting.summaryMarkdown, !summary.isEmpty { return (summary, "Notes") }
        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? nil : (notes, "My notes")
    }

    private static func detailBlock(_ meeting: Meeting, body: String, label: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return """
        ### \(meeting.displayTitle) — \(formatter.string(from: meeting.startedAt)) (\(label))

        \(body)
        """
    }

    private static func firstLine(of markdown: String?) -> String? {
        guard let markdown else { return nil }
        // Skip headings to reach the first real sentence.
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("|") else { continue }
            return String(trimmed.prefix(180))
        }
        return nil
    }

    // MARK: - Relevance

    /// For an index copy, the search text file — already lowercased, and
    /// rebuilt if stale — rather than decoding its meeting.json.
    private static func lowercasedTranscript(of meeting: Meeting) -> String {
        if meeting.transcriptLoaded { return meeting.transcriptText.lowercased() }
        guard meeting.hasTranscript else { return "" }
        return TranscriptSearchText.lowercasedText(for: meeting.id)
    }

    /// Words too common to discriminate between meetings.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "what", "when", "where", "who",
        "how", "did", "was", "were", "are", "you", "your", "our", "about", "from",
        "have", "has", "had", "said", "say", "tell", "any", "all", "can", "could",
        "would", "should", "there", "their", "they", "them", "then", "than", "into",
        "meeting", "meetings", "call", "calls", "discuss", "discussed", "talk",
        "talked", "mentioned", "last", "which", "been", "being", "does", "just"
    ]

    /// Terms from the question, plus the user's recent turns so a follow-up like
    /// "and what did they decide?" still retrieves the right meeting.
    private static func searchTerms(in question: String, history: [ChatMessage]) -> [String] {
        let recent = history.suffix(4).filter { $0.role == .user }.map(\.text)
        let text = ([question] + recent).joined(separator: " ")
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Array(Set(words))
    }

    /// Weighted keyword overlap. Deliberately simple — no embeddings, nothing to
    /// index or keep in sync — and weighted by how deliberate each field is: a
    /// term in a title or in the user's own notes means far more than one buried
    /// in a transcript.
    private static func relevance(of meeting: Meeting, terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let title = meeting.displayTitle.lowercased()
        let attendees = meeting.attendees.joined(separator: " ").lowercased()
        let notes = meeting.notes.lowercased()
        let summary = (meeting.summaryMarkdown ?? "").lowercased()
        let transcript = lowercasedTranscript(of: meeting)

        var score = 0
        for term in terms {
            if title.contains(term) { score += 8 }
            if attendees.contains(term) { score += 6 }
            if notes.contains(term) { score += 4 }
            if summary.contains(term) { score += 3 }
            // Repeated mentions in a transcript do carry signal, but with
            // diminishing returns so one long meeting cannot dominate.
            let mentions = transcript.components(separatedBy: term).count - 1
            if mentions > 0 { score += min(mentions, 5) }
        }
        return score
    }
}
