import AppKit
import ApplicationServices

/// Reads a call's name from the meeting app's own window title, for calls the
/// calendar knows nothing about — an ad-hoc Teams call, a meeting joined from a
/// link. Granola does the same.
///
/// Window titles are only readable through the Accessibility API, which needs
/// the user's permission (System Settings › Privacy & Security › Accessibility).
/// Without it this quietly returns nil and the recording keeps its default name.
enum CallWindowTitle {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Minutes to the Accessibility list.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The most likely meeting name among the app's windows, or nil.
    static func current(for detection: MeetingDetector.Detection) -> String? {
        guard isTrusted else { return nil }
        // A browser's windows are web pages, almost none of them the call.
        // Only a recognised meeting tab may name the recording.
        if detection.isAmbiguous { return BrowserMeeting.current(for: detection)?.name }
        let titles = runningApps(matching: detection).flatMap(windowTitles(of:))
        return bestTitle(from: titles, appName: detection.appName)
    }

    /// Picks the meeting's name out of an app's window titles. Separate from the
    /// Accessibility calls so the rules can be tested.
    ///
    /// Teams titles its windows "<name> | Microsoft Teams" (classic) or
    /// "<name> | <organisation> | <account>" (new Teams). The main window's
    /// name starts with a section (Chat, Calendar, Activity…); a call or
    /// meeting window's is the meeting title or the person called. Zoom and
    /// others use generic titles ("Zoom Meeting"), which say nothing and are
    /// skipped.
    static func bestTitle(from titles: [String], appName: String) -> String? {
        let candidates = titles.compactMap { raw -> String? in
            // Strips the app's own trailers: "| Microsoft Teams", and new
            // Teams' "| <organisation> | <account email>".
            guard var title = MeetingTitle.fromWindow(raw) else { return nil }
            // The main window carries its section: "Chat | Dana Whitfield". That
            // names whatever chat is open, not the call, so it is skipped.
            if let bar = title.range(of: " | "), sectionNames.contains(String(title[..<bar.lowerBound]).lowercased()) {
                return nil
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = title.lowercased()
            guard title.count >= 3, title.count <= 120,
                  !genericTitles.contains(lowered),
                  !sectionNames.contains(lowered),
                  lowered != appName.lowercased(),
                  !lowered.hasPrefix("microsoft teams") else { return nil }
            return title
        }
        // A meeting window is opened after the main window, so it is listed
        // last; and a real meeting name is rarely shorter than a section name.
        return candidates.last
    }

    private static let sectionNames: Set<String> = [
        "chat", "chats", "calendar", "activity", "teams", "calls", "onedrive", "files", "apps",
        "copilot", "communities", "meet", "people", "settings", "notifications", "search"
    ]

    private static let genericTitles: Set<String> = [
        "zoom meeting", "zoom", "zoom workplace", "meeting", "meeting controls", "webex", "webex meetings",
        "slack", "huddle", "facetime", "google meet", "meet", "untitled", "screen sharing",
        "sharing toolbar", "meeting compact view", "compact view", "notification", "teams notification"
    ]

    /// Every window title of every running conferencing app, with what would
    /// be picked — for `--test-call-title`.
    static func report() -> String {
        guard isTrusted else {
            return "Accessibility is not granted to Minutes, so window titles cannot be read.\n"
                + "Grant it in Settings › General › Permissions, then run this again."
        }
        var lines: [String] = []
        for app in SharedPrompts.Detection.apps where !app.ambiguous {
            let detection = MeetingDetector.Detection(bundleID: app.prefix, appName: app.name, isAmbiguous: false)
            let running = runningApps(matching: detection)
            guard !running.isEmpty else { continue }
            let titles = running.flatMap(windowTitles(of:))
            lines.append("\(app.name): \(titles.isEmpty ? "(no windows)" : titles.map { "\"\($0)\"" }.joined(separator: ", "))")
            lines.append("  → would name the recording: \(bestTitle(from: titles, appName: app.name) ?? "(nothing usable)")")
        }
        return lines.isEmpty ? "No conferencing app is running." : lines.joined(separator: "\n")
    }

    static func runningApps(matching detection: MeetingDetector.Detection) -> [NSRunningApplication] {
        // The process holding the microphone may be a helper; its windows
        // belong to the main app, which shares the bundle-ID prefix.
        let prefix = SharedPrompts.Detection.apps
            .first { $0.name == detection.appName }?.prefix.lowercased()
            ?? detection.bundleID.lowercased()
        return NSWorkspace.shared.runningApplications.filter {
            ($0.bundleIdentifier?.lowercased().hasPrefix(prefix) ?? false) && $0.activationPolicy == .regular
        }
    }

    static func windowTitles(of app: NSRunningApplication) -> [String] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not hang us: Accessibility calls block on the target.
        AXUIElementSetMessagingTimeout(element, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
            else { return nil }
            return title as? String
        }
    }
}
