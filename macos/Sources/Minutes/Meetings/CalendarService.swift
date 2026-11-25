import Foundation
import EventKit

/// Names a recording after the calendar event it overlaps, and pulls attendees
/// in as context for the summary.
///
/// Entirely opt-in. We never touch EKEventStore unless the user has enabled it in
/// settings, so the app never provokes a Calendar permission prompt on its own.
final class CalendarService {
    static let shared = CalendarService()

    struct Event {
        var title: String
        var attendees: [String]
        /// Other invitees' addresses (not the user's), when the calendar has them.
        var attendeeEmails: [String] = []
        /// A Zoom/Teams/Meet/Webex-style join link in the event, if any. Its
        /// presence is what lets a browser call auto-record: a browser holding
        /// the microphone is ambiguous on its own, but not during a scheduled
        /// video meeting.
        var meetingLink: URL?
    }

    /// A scheduled meeting still to come (or under way), for the Coming up list
    /// and the one-minute reminder.
    struct Upcoming: Identifiable, Equatable, Sendable {
        /// Event identifier plus start, since a recurring series shares one
        /// identifier across its occurrences.
        var id: String
        var title: String
        var start: Date
        var end: Date
        var meetingLink: URL?
        /// Other invitees' names, for a pre-meeting brief.
        var attendees: [String] = []
    }

    /// Meetings between now and `horizon`: timed events you have not declined
    /// that look like meetings — invitees, or a join link. Solo blocks such as
    /// "Focus time" and "Lunch" are not meetings and never ring.
    func upcomingEvents(until horizon: Date) -> [Upcoming] {
        guard AppSettings.shared.calendarEnabled,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let now = Date()
        guard let calendars = includedCalendars() else { return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60 * 60),
                                                end: horizon, calendars: calendars)
        return store.events(matching: predicate)
            .filter { $0.endDate > now && Self.looksLikeMeeting($0) }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                Upcoming(id: "\(event.eventIdentifier ?? UUID().uuidString)@\(event.startDate.timeIntervalSince1970)",
                         title: event.title ?? "Meeting",
                         start: event.startDate,
                         end: event.endDate,
                         meetingLink: Self.meetingLink(in: event),
                         attendees: (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { $0.name })
            }
    }

    /// A timed event you have not declined that has other people in it or a
    /// join link. "Focus time" and "Lunch" are on the calendar, but a call that
    /// starts during them is still an impromptu call.
    static func looksLikeMeeting(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.status != .canceled else { return false }
        if let me = event.attendees?.first(where: \.isCurrentUser),
           me.participantStatus == .declined { return false }
        return (event.attendees?.count ?? 0) >= 2 || meetingLink(in: event) != nil
    }

    /// Whether Minutes can read the calendar, as the user would describe it.
    enum Access { case granted, notAsked, denied }

    static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// Hosts whose links mean "this event is a video call".
    private static let meetingHosts = [
        "zoom.us", "zoom.com", "teams.microsoft.com", "teams.live.com", "meet.google.com",
        "webex.com", "gotomeeting.com", "meet.goto.com", "chime.aws", "whereby.com",
        "meet.jit.si", "bluejeans.com", "ringcentral.com", "dialpad.com", "slack.com/huddle"
    ]

    private static func meetingLink(in event: EKEvent) -> URL? {
        if let url = event.url, isMeetingLink(url.absoluteString) { return url }
        return meetingLink(inText: [event.location, event.notes].compactMap { $0 }.joined(separator: "\n"))
    }

    /// The first join link in free text — Outlook and Google both put it in the
    /// location or the description, among other links.
    static func meetingLink(inText text: String) -> URL? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { isMeetingLink($0.absoluteString) }
    }

    private static func isMeetingLink(_ string: String) -> Bool {
        let lowered = string.lowercased()
        return meetingHosts.contains { lowered.contains($0) }
    }

    private let store = EKEventStore()

    /// One calendar macOS has, for the picker in Settings.
    struct CalendarInfo: Identifiable, Hashable, Sendable {
        var id: String
        var title: String
        /// The account it syncs from: "Exchange", "iCloud", "On My Mac".
        var account: String
        var isExchange: Bool
    }

    /// Every event calendar in the macOS calendar store, grouped by account.
    func calendars() -> [CalendarInfo] {
        guard Self.access == .granted else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                account: $0.source?.title ?? "Other",
                                isExchange: $0.source?.sourceType == .exchange) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Whether a Microsoft 365 / Exchange account is synced into macOS — the
    /// only way an Outlook calendar reaches other apps. New Outlook keeps its
    /// own copy private, and its AppleScript sees an empty stub.
    var hasExchangeAccount: Bool {
        Self.access == .granted && store.sources.contains { $0.sourceType == .exchange }
    }

    /// The calendars to read: all of them except those switched off in
    /// Settings. nil when every calendar is switched off, so nothing is read.
    private func includedCalendars() -> [EKCalendar]? {
        let all = store.calendars(for: .event)
        let excluded = AppSettings.shared.excludedCalendarIDs
        let included = all.filter { !excluded.contains($0.calendarIdentifier) }
        return included.isEmpty && !all.isEmpty ? nil : included
    }

    /// System Settings › Internet Accounts, where an Exchange account is added.
    static let internetAccountsURL = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!
    private var hasAccess = false

    private init() {}

    /// Requests access; returns whether it was granted.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            hasAccess = try await store.requestFullAccessToEvents()
        } catch {
            Log.warn("Calendar access failed: \(error.localizedDescription)")
            hasAccess = false
        }
        return hasAccess
    }

    /// The event happening right now, if any. Prefers the event whose window most
    /// tightly contains the current moment, so a day-long "PTO" block doesn't win
    /// over the actual 30-minute call.
    func currentEvent() -> Event? { event(at: Date()) }

    /// The meeting that was on at `now` — for naming a recording after the
    /// fact, when the calendar was not readable (or not yet synced) at the
    /// time it was made.
    func event(at now: Date) -> Event? {
        guard AppSettings.shared.calendarEnabled else { return nil }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }

        guard let calendars = includedCalendars() else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60),
                                                end: now.addingTimeInterval(15 * 60),
                                                calendars: calendars)
        let candidates = store.events(matching: predicate).filter { event in
            // Only meetings: a call during a focus block is not that block's
            // call, and must not be named after it or treated as scheduled.
            guard Self.looksLikeMeeting(event) else { return false }
            // Allow a little slack for joining early or running over.
            return event.startDate <= now.addingTimeInterval(10 * 60)
                && event.endDate >= now.addingTimeInterval(-10 * 60)
        }

        guard let best = candidates.min(by: { left, right in
            left.endDate.timeIntervalSince(left.startDate) < right.endDate.timeIntervalSince(right.startDate)
        }) else { return nil }

        let attendees = (best.attendees ?? []).compactMap { participant -> String? in
            participant.name ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }

        let emails = (best.attendees ?? []).compactMap { participant -> String? in
            guard !participant.isCurrentUser,
                  participant.url.scheme?.lowercased() == "mailto" else { return nil }
            let address = participant.url.absoluteString.dropFirst("mailto:".count)
            return address.removingPercentEncoding?.lowercased()
        }

        return Event(title: best.title ?? "", attendees: attendees, attendeeEmails: emails,
                     meetingLink: Self.meetingLink(in: best))
    }
}

extension CalendarService.Upcoming {
    /// The shared "meeting-brief" recipe, filled in for this event.
    var briefPrompt: String {
        let template = SharedPrompts.Recipes.all.first { $0.id == "meeting-brief" }?.prompt ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        return template
            .replacingOccurrences(of: "{{title}}", with: title)
            .replacingOccurrences(of: "{{start}}", with: formatter.string(from: start))
            .replacingOccurrences(of: "{{attendees}}",
                                  with: attendees.isEmpty ? "" : ", with \(attendees.joined(separator: ", "))")
    }
}
