import Foundation

enum Speaker: String, Codable, Sendable {
    case me
    case others
    case unknown

    var label: String {
        switch self {
        case .me: return "You"
        case .others: return "Them"
        case .unknown: return "Speaker"
        }
    }
}

/// A timestamped chunk of refined transcript. `speaker` is derived from which
/// audio source (mic vs system) carried more energy during the segment's range.
struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var speaker: Speaker
    var text: String

    var timestampLabel: String {
        let total = Int(start)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

enum MeetingState: String, Codable, Sendable {
    case recording
    case transcribing
    case summarizing
    case complete
    case failed

    var isBusy: Bool { self == .transcribing || self == .summarizing }
}

struct Meeting: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var state: MeetingState = .recording

    /// Bundle identifier of the conferencing app that triggered auto-detection.
    var detectedAppBundleID: String?
    var detectedAppName: String?

    /// Pulled from Calendar when an event overlaps the recording window.
    var calendarEventTitle: String?
    var attendees: [String] = []
    /// Invitees' email addresses, excluding the user's own — the source of the
    /// Companies filter, since a name alone says nothing about where someone works.
    var attendeeEmails: [String] = []
    /// The folder this meeting is filed in, by name. Nil means unfiled.
    var folder: String?
    /// Names the user gave the two sides, keyed by `Speaker` raw value — "me"
    /// becomes their own name, "others" the person they were talking to.
    var speakerNames: [String: String] = [:]

    /// The user's own notes, typed while the meeting runs. Granola's core idea:
    /// these steer the summary rather than being replaced by it.
    var notes: String = ""

    /// Rough text from Apple's on-device transcriber, shown live.
    var liveTranscript: String = ""

    /// High-accuracy Whisper output with speaker attribution.
    var segments: [TranscriptSegment] = []

    var summaryMarkdown: String?
    var templateID: String = SummaryTemplate.general.id
    /// The template the current summary was actually written with. Lets the UI
    /// point out that changing the style has left the existing notes stale.
    var summaryTemplateID: String?
    /// Set when the user edits the generated notes, so regenerating can warn
    /// that it would replace those edits.
    var summaryEditedAt: Date?
    var failureReason: String?


    /// Keys this build does not know — written by a newer build or the Windows
    /// app — carried through untouched, so saving never drops them.
    var unknownFields: [String: JSONValue] = [:]

    /// Whether `segments` and `liveTranscript` hold this meeting's transcript.
    ///
    /// The library index (`MeetingStore.meetings`) leaves transcripts on disk —
    /// they are most of a library's size, and nothing in the list needs them —
    /// so an index copy has both empty and this false. `hasSegments` and
    /// `hasTranscript` still answer for it; anything that reads the text gets a
    /// full copy from `MeetingStore.fullMeeting(id:)` or `loadedTranscriptText()`.
    /// Never encoded.
    var transcriptLoaded = true
    /// For an index copy, what the transcript on disk holds.
    var indexedSegmentCount = 0
    var indexedHasLiveTranscript = false

    /// True when Whisper's refined transcript exists, loaded or not.
    var hasSegments: Bool {
        transcriptLoaded ? !segments.isEmpty : indexedSegmentCount > 0
    }

    /// True when `transcriptText` is non-empty, loaded or not.
    var hasTranscript: Bool {
        hasSegments || (transcriptLoaded ? !liveTranscript.isEmpty : indexedHasLiveTranscript)
    }

    /// This meeting with its transcript dropped, for the library index.
    var indexCopy: Meeting {
        guard transcriptLoaded else { return self }
        var copy = self
        copy.indexedSegmentCount = segments.count
        copy.indexedHasLiveTranscript = !liveTranscript.isEmpty
        copy.segments = []
        copy.liveTranscript = ""
        copy.transcriptLoaded = false
        return copy
    }

    /// `transcriptText`, read from disk when this is an index copy. Safe off
    /// the main thread; for the Ask context and the MCP server.
    func loadedTranscriptText() -> String {
        if transcriptLoaded { return transcriptText }
        guard hasTranscript else { return "" }
        return MeetingStore.loadMeeting(id: id)?.transcriptText ?? ""
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var durationLabel: String {
        let total = Int(duration)
        if total >= 3600 {
            return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
        }
        if total >= 60 {
            return String(format: "%dm %02ds", total / 60, total % 60)
        }
        return "\(total)s"
    }

    /// True when the chosen style no longer matches the notes on screen.
    var summaryIsStale: Bool {
        guard summaryMarkdown?.isEmpty == false, let written = summaryTemplateID else { return false }
        return written != templateID
    }

    /// Best available transcript text, preferring the refined segments.
    var transcriptText: String {
        guard !segments.isEmpty else { return liveTranscript }
        return segments
            .map { "[\($0.timestampLabel)] \(label(for: $0.speaker)): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Organisations met with, from invitee email domains. Webmail domains say
    /// nothing about a company, so they are left out.
    var companies: [String] {
        let domains = attendeeEmails.compactMap { email -> String? in
            guard let at = email.lastIndex(of: "@") else { return nil }
            let domain = email[email.index(after: at)...].lowercased()
            return Self.webmailDomains.contains(domain) ? nil : domain
        }
        return Array(Set(domains)).sorted()
    }

    static let webmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "icloud.com", "me.com", "mac.com", "yahoo.com", "aol.com", "proton.me", "protonmail.com"
    ]

    /// A speaker's label in this meeting: the name the user gave it, else the
    /// default You / Them / Speaker.
    func label(for speaker: Speaker) -> String {
        let name = speakerNames[speaker.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? speaker.label : name
    }

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        // An empty calendar title is no title: show "Meeting", as Windows does.
        if let cal = calendarEventTitle, !cal.isEmpty { return cal }
        return "Meeting"
    }

    // File layout inside the meeting's own directory.
    var directory: URL { AppPaths.meetingDir(id) }
    var metadataFile: URL { directory.appendingPathComponent("meeting.json") }
    var mixedAudioFile: URL { directory.appendingPathComponent("audio.wav") }
    var energyLogFile: URL { directory.appendingPathComponent("energy.bin") }
    var summaryFile: URL { directory.appendingPathComponent("summary.md") }
}

// MARK: - Tolerant decoding
//
// The synthesized decoder ignores property defaults and fails on any missing key
// or unrecognised enum value — and a meeting that fails to decode silently
// disappears from the library. shared/spec/meeting-format.md makes every field
// optional except `id`, `title` and `startedAt`, so a file from an older build,
// a newer one, or the Windows app must still load. Encoding stays synthesized.

extension Speaker {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Speaker(rawValue: raw) ?? .unknown
    }
}

extension MeetingState {
    /// A state this build does not know comes from a newer one; treating it as
    /// failed keeps the meeting visible and offers a retry.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingState(rawValue: raw) ?? .failed
    }
}

extension TranscriptSegment {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(TimeInterval.self, forKey: .end) ?? start
        speaker = try c.decodeIfPresent(Speaker.self, forKey: .speaker) ?? .unknown
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

extension Meeting {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, startedAt, endedAt, state, detectedAppBundleID, detectedAppName
        case calendarEventTitle, attendees, attendeeEmails, folder, speakerNames, notes, liveTranscript, segments, summaryMarkdown
        case templateID, summaryTemplateID, summaryEditedAt, failureReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        state = try c.decodeIfPresent(MeetingState.self, forKey: .state) ?? .complete
        detectedAppBundleID = try c.decodeIfPresent(String.self, forKey: .detectedAppBundleID)
        detectedAppName = try c.decodeIfPresent(String.self, forKey: .detectedAppName)
        calendarEventTitle = try c.decodeIfPresent(String.self, forKey: .calendarEventTitle)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        attendeeEmails = try c.decodeIfPresent([String].self, forKey: .attendeeEmails) ?? []
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        if decoder.userInfo[.meetingIndexOnly] as? Bool == true {
            // Count the segments without building them: the strings are most
            // of the file, and the index has no use for them.
            indexedSegmentCount = try c.decodeIfPresent([SkippedValue].self, forKey: .segments)?.count ?? 0
            indexedHasLiveTranscript = !(try c.decodeIfPresent(String.self, forKey: .liveTranscript) ?? "").isEmpty
            transcriptLoaded = false
        } else {
            liveTranscript = try c.decodeIfPresent(String.self, forKey: .liveTranscript) ?? ""
            segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        }
        summaryMarkdown = try c.decodeIfPresent(String.self, forKey: .summaryMarkdown)
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID) ?? SummaryTemplate.general.id
        summaryTemplateID = try c.decodeIfPresent(String.self, forKey: .summaryTemplateID)
        summaryEditedAt = try c.decodeIfPresent(Date.self, forKey: .summaryEditedAt)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let all = try decoder.container(keyedBy: AnyKey.self)
        for key in all.allKeys where !known.contains(key.stringValue) {
            unknownFields[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        // An index copy would write an empty transcript over the real one.
        guard transcriptLoaded else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Meeting \(id) is an index copy without its transcript"))
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(detectedAppBundleID, forKey: .detectedAppBundleID)
        try c.encodeIfPresent(detectedAppName, forKey: .detectedAppName)
        try c.encodeIfPresent(calendarEventTitle, forKey: .calendarEventTitle)
        try c.encode(attendees, forKey: .attendees)
        if !attendeeEmails.isEmpty { try c.encode(attendeeEmails, forKey: .attendeeEmails) }
        try c.encodeIfPresent(folder, forKey: .folder)
        if !speakerNames.isEmpty { try c.encode(speakerNames, forKey: .speakerNames) }
        try c.encode(notes, forKey: .notes)
        try c.encode(liveTranscript, forKey: .liveTranscript)
        try c.encode(segments, forKey: .segments)
        try c.encodeIfPresent(summaryMarkdown, forKey: .summaryMarkdown)
        try c.encode(templateID, forKey: .templateID)
        try c.encodeIfPresent(summaryTemplateID, forKey: .summaryTemplateID)
        try c.encodeIfPresent(summaryEditedAt, forKey: .summaryEditedAt)
        try c.encodeIfPresent(failureReason, forKey: .failureReason)

        var extra = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in unknownFields {
            try extra.encode(value, forKey: AnyKey(stringValue: key))
        }
    }
}

extension CodingUserInfoKey {
    /// Set to `true` to decode a `Meeting` without its transcript.
    static let meetingIndexOnly = CodingUserInfoKey(rawValue: "meetingIndexOnly")!
}

/// Decodes any JSON value and keeps nothing.
private struct SkippedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Any JSON value, for carrying unrecognised fields through a save.
enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
