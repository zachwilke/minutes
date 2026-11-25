import Foundation

/// Which meeting a browser is in, read from its window titles.
///
/// A browser holding the microphone could be anything — a voice memo site, a
/// dictation extension, a Discord tab — so on its own it only ever asks. But
/// the page title says which it is. Google Meet titles its tab "Meet - <code>"
/// or "Meet – <name>"; Teams on the web ends its titles "| Microsoft Teams";
/// Zoom's web client is "Zoom Meeting". When the front tab is one of those,
/// this is not "Chrome is using your microphone", it is a Google Meet call, and
/// it is treated like one.
///
/// Only the window title is read — the active tab's — and only through the
/// Accessibility permission the app already uses to name Teams calls. A call
/// in a background tab is not recognised and falls back to the plain question.
enum BrowserMeeting {
    struct Match: Equatable, Sendable {
        /// "Google Meet", "Microsoft Teams", "Zoom", …
        var service: String
        /// The meeting's own name, when the title carries one.
        var name: String?
    }

    /// The meeting among a browser's window titles, front window first.
    static func identify(_ titles: [String]) -> Match? {
        for raw in titles {
            if let match = identify(raw) { return match }
        }
        return nil
    }

    static func identify(_ raw: String) -> Match? {
        let title = stripped(raw)
        let lowered = title.lowercased()

        // Google Meet: "Meet - abc-defg-hij", "Meet – Weekly sync", "Google Meet".
        for prefix in ["Meet - ", "Meet – ", "Meet — ", "Meet: "] where title.hasPrefix(prefix) {
            return Match(service: "Google Meet", name: meetName(String(title.dropFirst(prefix.count))))
        }
        if lowered.hasSuffix("- google meet") || lowered.hasSuffix("– google meet") {
            let name = title.components(separatedBy: " - ").first ?? ""
            return Match(service: "Google Meet", name: meetName(name))
        }
        if lowered == "google meet" { return Match(service: "Google Meet", name: nil) }

        // Teams on the web: "<name> | Microsoft Teams", or new Teams' trailers.
        if lowered.contains("microsoft teams") || lowered.hasSuffix("| teams") {
            return Match(service: "Microsoft Teams", name: MeetingTitle.fromWindow(title))
        }
        // Zoom's web client.
        if lowered.hasPrefix("zoom meeting") || lowered.hasPrefix("zoom webinar")
            || lowered.contains("zoom workplace") || lowered.hasSuffix("- zoom") {
            return Match(service: "Zoom", name: nil)
        }
        if lowered.contains("webex") { return Match(service: "Webex", name: nil) }
        if lowered.contains("whereby") { return Match(service: "Whereby", name: nil) }
        if lowered.contains("jitsi meet") { return Match(service: "Jitsi Meet", name: nil) }
        return nil
    }

    /// A Meet title's name, unless it is only the meeting code.
    private static func meetName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.lowercased() == "google meet" { return nil }
        if name.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil { return nil }
        return name
    }

    /// Without the browser's own name, the unread-count prefix some sites add
    /// ("(2) "), and the audio/recording markers some browsers append.
    private static func stripped(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        for suffix in [" - Google Chrome", " — Mozilla Firefox", " - Mozilla Firefox", " - Microsoft Edge",
                       " - Microsoft\u{200B} Edge", " - Brave", " - Vivaldi", " - Arc", " – Arc", " - Dia"] {
            if let range = title.range(of: suffix) { title = String(title[..<range.lowerBound]) }
        }
        for marker in [" - Audio playing", " - Camera or microphone recording", " - Microphone recording"] {
            title = title.replacingOccurrences(of: marker, with: "")
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Reads the browser's window titles. Accessibility calls block on the
    /// target app, so call this off the main thread.
    static func current(for detection: MeetingDetector.Detection) -> Match? {
        guard detection.isAmbiguous, CallWindowTitle.isTrusted else { return nil }
        let titles = CallWindowTitle.runningApps(matching: detection).flatMap(CallWindowTitle.windowTitles(of:))
        return identify(titles)
    }
}
