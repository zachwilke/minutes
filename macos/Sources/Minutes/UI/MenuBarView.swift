import SwiftUI

/// The menu bar popover: start or stop a recording, see what's happening, and
/// jump to a recent meeting.
struct MenuBarView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var chat: ChatController
    @Environment(\.openWindow) private var openWindow
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let detection = coordinator.pendingDetection {
                detectionPrompt(detection)
                Divider()
            }

            if coordinator.phase.isRecording {
                recordingSection
                Divider()
            }

            ComingUpList(reminders: coordinator.reminders,
                         onBrief: { event in
                             chat.send(event.briefPrompt)
                             coordinator.requestedSidebarItem = .chat
                             openMain()
                         })

            recentSection
            Divider()
            footer
        }
        .frame(width: 330)
        .background(BrandBackground(translucent: AppSettings.shared.translucentWindow))
        .tint(Palette.ink)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Minutes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                StatusLine(coordinator: coordinator, activity: coordinator.activity)
            }
            Spacer()
            recordButton
        }
        .padding(14)
    }

    /// Its own view so the once-a-second clock only re-renders this Text, not
    /// the whole popover.
    private struct StatusLine: View {
        @ObservedObject var coordinator: RecordingCoordinator
        @ObservedObject var activity: RecordingActivity

        var body: some View {
            Text(line)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        private var line: String {
            if coordinator.phase.isRecording {
                return "Recording — \(MenuBarView.timeLabel(activity.elapsed))"
            }
            if case .failed(let reason) = coordinator.phase { return reason }
            // Recording and processing are independent; when idle, report the
            // busiest pipeline so a background transcription stays visible.
            if let pipeline = coordinator.processing.values.first {
                switch pipeline {
                case .transcribing(let progress): return "Transcribing — \(Int(progress * 100))%"
                case .summarizing: return "Writing notes with Claude…"
                }
            }
            return AppSettings.shared.autoDetectMeetings ? "Watching for meetings" : "Idle"
        }
    }

    private var recordButton: some View {
        RecordButton(isRecording: coordinator.phase.isRecording,
                     isBusy: false,
                     size: 14,
                     start: { Task { await coordinator.startRecording() } },
                     stop: { Task { await coordinator.stopRecording() } })
    }

    private func detectionPrompt(_ detection: MeetingDetector.Detection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Palette.warning)
                Text(detection.isRecognisedMeeting
                     ? "\(detection.displayName) call detected"
                     : "\(detection.appName) is using your microphone")
                    .font(.system(size: 12, weight: .medium))
            }
            Text(detection.isRecognisedMeeting
                 ? "Record it and write notes when it ends?"
                 : "This might be a meeting, or just audio in a browser tab.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                IconButton(symbol: "record.circle",
                           help: "Record this meeting",
                           emphasis: .prominent) { coordinator.acceptPendingDetection() }
                IconButton(symbol: "xmark",
                           help: "Ignore — don't record this") { coordinator.dismissPendingDetection() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.warning.opacity(0.10))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meeting = coordinator.activeMeeting {
                Text(meeting.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            PopoverMeters(meters: coordinator.activity.meters)
            HStack(spacing: 8) {
                Button {
                    if let id = coordinator.activeMeetingID { coordinator.requestedMeetingID = id }
                    openMain()
                } label: {
                    Label("Notes", systemImage: "square.and.pencil")
                }
                Spacer()
                Button("Discard…", role: .destructive) { confirmDiscard = true }
                Button {
                    Task { await coordinator.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.recording)
            }
            .controlSize(.small)
            .font(.system(size: 11))
            .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
                Button("Discard Recording", role: .destructive) {
                    Task { await coordinator.discardRecording() }
                }
            } message: {
                Text("The audio and anything transcribed so far are deleted, and nothing is written.")
            }
        }
        .padding(14)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.inkTertiary)
                .padding(.horizontal, 14)
                .padding(.top, 11)

            if store.meetings.isEmpty {
                Text("No meetings yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
            } else {
                ForEach(store.meetings.prefix(5)) { meeting in
                    Button {
                        // Ask the window to show this meeting, not just open.
                        coordinator.requestedMeetingID = meeting.id
                        openMain()
                    } label: {
                        HStack(spacing: 8) {
                            Text(meeting.displayTitle)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Spacer()
                            Text(Self.relative(meeting.startedAt))
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inkTertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .hoverFill(radius: Radius.chip)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                }
                Spacer().frame(height: 8)
            }
        }
    }

    /// Meters as a leaf, so level ticks re-render two capsules, not the popover.
    private struct PopoverMeters: View {
        @ObservedObject var meters: RecordingActivity.Meters

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                LevelMeter(label: "You", level: meters.levels.mic)
                LevelMeter(label: "Them", level: meters.levels.system)
            }
        }
    }

    private var footer: some View {
        HStack {
            IconButton(symbol: "arrow.up.forward.app",
                       help: "Open the Minutes window",
                       emphasis: .plain) { openMain() }
            Spacer()
            IconButton(symbol: "power",
                       help: "Quit Minutes",
                       emphasis: .plain) { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func timeLabel(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Horizontal input level bar, used in the menu bar and the recording header.
struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.fill)
                    Capsule()
                        .fill(Palette.meterGradient)
                        .frame(width: max(0, geometry.size.width * CGFloat(normalized)))
                        .animation(.linear(duration: 0.1), value: normalized)
                }
            }
            .frame(height: 6)
        }
    }

    /// RMS of speech sits low in a linear scale, so this uses a rough dB curve to
    /// make the meter actually move while someone is talking.
    private var normalized: Double { Self.normalized(level) }

    static func normalized(_ level: Float) -> Double {
        let value = Double(max(level, 1e-5))
        let decibels = 20 * log10(value)
        return min(1, max(0, (decibels + 55) / 55))
    }
}

/// What sits in the menu bar: the icon, plus — like Granola — a little text
/// when it is worth a glance: the clock while recording, or the next meeting
/// when one starts within fifteen minutes.
///
/// Its own view observing the activity and reminders directly; the App body
/// only re-evaluates for the coordinator's own changes, so a label built there
/// would never tick.
struct MenuBarLabel: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var activity: RecordingActivity
    @ObservedObject var reminders: MeetingReminders
    @ObservedObject private var settings = AppSettings.shared

    /// How soon a meeting must start to be named in the bar.
    static let lookahead: TimeInterval = 15 * 60

    var body: some View {
        // Deliberately just an icon, or an icon with a title. A TimelineView or
        // a custom HStack here sends the status item into an endless update
        // loop at launch — every redraw re-requests one — and the app hangs.
        // No timer is needed: the clock ticks through `activity`, and the
        // reminders publish every 30 s, which re-renders the countdown. The
        // recording pulse rides the same once-a-second tick.
        let icon = Image(nsImage: MenuBarIcon.image(state))
            // The recording image carries its own red; the others are
            // templates the system tints.
            .renderingMode(isRecording ? .original : .template)
        if settings.menuBarText, let text = text(at: Date()) {
            Label { Text(text) } icon: { icon }
                .labelStyle(.titleAndIcon)
        } else {
            icon
        }
    }

    private var isRecording: Bool { coordinator.phase.isRecording }

    private var state: MenuBarIcon.State {
        if isRecording { return .recording(lit: Int(activity.elapsed) % 2 == 0) }
        return coordinator.processing.isEmpty ? .idle : .processing
    }

    private func text(at now: Date) -> String? {
        if coordinator.phase.isRecording {
            return MenuBarView.timeLabel(activity.elapsed)
        }
        guard let next = reminders.upcoming.first(where: {
            $0.end > now && $0.start.timeIntervalSince(now) < Self.lookahead
        }) else { return nil }
        let title = next.title.count > 22 ? String(next.title.prefix(21)) + "…" : next.title
        let minutes = Int(ceil(next.start.timeIntervalSince(now) / 60))
        return minutes <= 0 ? "\(title) · now" : "\(title) · \(minutes)m"
    }
}

/// The next few calendar meetings, each one click from being joined and
/// recorded — the part of Granola's menu bar that makes it the place to start.
private struct ComingUpList: View {
    @ObservedObject var reminders: MeetingReminders
    let onBrief: (CalendarService.Upcoming) -> Void
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        let events = Array(reminders.upcoming.prefix(3))
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("COMING UP")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 11)
                ForEach(events) { event in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.system(size: 12)).lineLimit(1)
                            Text(Self.when(event))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        IconButton(symbol: "text.page.badge.magnifyingglass",
                                   help: "Brief me for this meeting", emphasis: .plain, size: 11) {
                            onBrief(event)
                        }
                        if !coordinator.phase.isRecording {
                            IconButton(symbol: "record.circle",
                                       help: event.meetingLink == nil ? "Record this meeting"
                                                                      : "Join the call and record it",
                                       emphasis: .plain, tint: Palette.recording, size: 12) {
                                coordinator.joinAndRecord(title: event.title, link: event.meetingLink)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 3)
                }
                Spacer().frame(height: 6)
            }
            Divider()
        }
    }

    private static func when(_ event: CalendarService.Upcoming) -> String {
        let range = Formats.timeRange(event.start, event.end)
        let minutes = Int(ceil(event.start.timeIntervalSinceNow / 60))
        if minutes <= 0 { return "Now · \(range)" }
        if minutes < 60 { return "In \(minutes) min · \(range)" }
        return Calendar.current.isDateInToday(event.start) ? range : "Tomorrow · \(range)"
    }
}
