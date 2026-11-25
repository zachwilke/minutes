import Foundation
import EventKit
import Combine

/// Keeps the Coming up list current and rings a minute before each meeting.
///
/// The reminder is what turns a calendar into a recording without a click in
/// the wrong app: Join & Record opens the call link and starts recording, and
/// the call that then grabs the microphone is adopted by that recording, so it
/// also stops when the call ends.
@MainActor
final class MeetingReminders: ObservableObject {
    /// The rest of today's meetings, plus anything in the next few hours.
    @Published private(set) var upcoming: [CalendarService.Upcoming] = []

    /// Fired when a reminder is due. The coordinator decides how to present it.
    var onReminder: ((CalendarService.Upcoming) -> Void)?

    private var timer: Timer?
    private var lastSummary = ""
    private var changeObserver: NSObjectProtocol?
    private var reminded: Set<String> = []
    private var refreshing = false

    /// How early the reminder rings.
    nonisolated static let lead: TimeInterval = 60

    func start() {
        stop()
        // Thirty seconds keeps a one-minute lead within half a minute of exact.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        upcoming = []
    }

    func refresh() {
        guard AppSettings.shared.calendarEnabled, !refreshing else {
            if !AppSettings.shared.calendarEnabled { upcoming = [] }
            return
        }
        refreshing = true
        // To the end of tomorrow, so Home can show the next day the way Granola
        // does. Reminders are due-based, so a longer horizon rings nothing early.
        let horizon = max(Calendar.current.startOfDay(for: Date()).addingTimeInterval(2 * 86_400),
                          Date().addingTimeInterval(6 * 3600))
        // EKEventStore queries can stall; never on the main thread.
        Task {
            let (events, calendars, exchange) = await Task.detached(priority: .utility) {
                (CalendarService.shared.upcomingEvents(until: horizon),
                 CalendarService.shared.calendars().count,
                 CalendarService.shared.hasExchangeAccount)
            }.value
            refreshing = false
            // Logged when the answer changes, not every 30 s: what "my
            // meetings don't show" comes down to. Counts only, no titles.
            let summary = "Calendar: \(events.count) meeting\(events.count == 1 ? "" : "s") ahead from "
                + "\(calendars) calendar\(calendars == 1 ? "" : "s"), Exchange account \(exchange ? "present" : "absent")"
            if summary != lastSummary {
                Log.info(summary)
                lastSummary = summary
            }
            upcoming = events
            ringDueReminders(events)
        }
    }

    private func ringDueReminders(_ events: [CalendarService.Upcoming]) {
        guard AppSettings.shared.meetingReminders else { return }
        for event in Self.due(events, now: Date(), alreadyReminded: reminded) {
            reminded.insert(event.id)
            Log.info("Reminder for \(event.title) at \(event.start)")
            onReminder?(event)
        }
    }

    /// Events whose reminder is due: starting within the lead, and not already
    /// well under way — a meeting that started ten minutes ago gets no
    /// "starts in a minute".
    nonisolated static func due(_ events: [CalendarService.Upcoming], now: Date,
                                alreadyReminded: Set<String>) -> [CalendarService.Upcoming] {
        events.filter { event in
            let untilStart = event.start.timeIntervalSince(now)
            return !alreadyReminded.contains(event.id) && untilStart <= lead && untilStart > -120
        }
    }
}
