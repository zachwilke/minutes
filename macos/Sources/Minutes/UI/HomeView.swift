import SwiftUI

/// The front page: what is coming up, then every meeting, newest first.
///
/// Also serves a folder, which is the same page narrowed to one folder and
/// without the calendar.
struct HomeView: View {
    @Binding var selection: SidebarItem?
    /// nil for Home; a name for a folder.
    var folder: String?
    @Binding var search: String
    /// Set by the toolbar's search button or ⌘F; consumed here.
    @Binding var searchRequested: Bool

    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var chat: ChatController

    @State private var filter: LibraryFilter?
    @State private var searchActive = false
    @FocusState private var searchFocused: Bool
    /// Deleting asks first; it moves the meeting to Recently Deleted.
    @State private var pendingDelete: Meeting?
    @State private var newFolderFor: Meeting?
    @State private var newFolderName = ""

    private var isSearching: Bool { !search.isEmpty || filter != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if searchActive || isSearching {
                    searchRow.padding(.top, 14)
                }
                if folder == nil && !isSearching {
                    ComingUpCard(reminders: coordinator.reminders, selection: $selection)
                        .padding(.top, 18)
                }
                meetingList.padding(.top, folder == nil && !isSearching ? 34 : 22)
            }
            .frame(maxWidth: Layout.homeWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Layout.documentGutter)
            .padding(.top, 26)
            // Clear of the Ask bar.
            .padding(.bottom, 110)
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) {
            AskBar(suggestion: SharedPrompts.Recipes.named("my-commitments"),
                   isBusy: chat.isResponding) { question in
                selection = .chat
                chat.send(question)
            }
            .frame(maxWidth: Layout.homeWidth + 40)
            .padding(.horizontal, Layout.documentGutter - 20)
            .padding(.bottom, 18)
        }
        .onChange(of: searchRequested) { _, requested in
            guard requested else { return }
            searchActive = true
            searchFocused = true
            searchRequested = false
        }
        .onAppear {
            if searchRequested {
                searchActive = true
                searchFocused = true
                searchRequested = false
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayTitle ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { meeting in
            Button("Delete Meeting", role: .destructive) {
                store.moveToTrash(meeting)
                pendingDelete = nil
            }
        } message: { _ in
            Text("It moves to Recently Deleted, where it can be restored for 30 days.")
        }
        .alert("New Folder", isPresented: Binding(get: { newFolderFor != nil },
                                                  set: { if !$0 { newFolderFor = nil } })) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let meeting = newFolderFor, !name.isEmpty {
                    store.update(id: meeting.id) { $0.folder = name }
                }
                newFolderFor = nil
            }
            Button("Cancel", role: .cancel) { newFolderFor = nil }
        } message: {
            Text("The meeting is moved into it.")
        }
    }

    // MARK: - Header

    private var header: some View {
        Text(folder ?? (isSearching ? "Search" : "Coming up"))
            .font(Typeface.display())
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.inkTertiary)
                TextField(folder.map { "Search \($0)" } ?? "Search meetings", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink)
                    .focused($searchFocused)
                    .onExitCommand { closeSearch() }
                if !search.isEmpty {
                    IconButton(symbol: "xmark.circle.fill", help: "Clear the search",
                               emphasis: .plain, size: 11) { search = "" }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Palette.raised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            }

            filterMenu

            if let filter {
                HStack(spacing: 5) {
                    Image(systemName: filter.symbol).font(.system(size: 9))
                    Text(filter.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    IconButton(symbol: "xmark", help: "Remove this filter", emphasis: .plain, size: 8) {
                        self.filter = nil
                    }
                }
                .foregroundStyle(Palette.ink)
                .padding(.leading, 9)
                .background { Capsule().fill(Palette.fill) }
            }

            IconButton(symbol: "xmark", help: "Close search", emphasis: .plain, size: 11) { closeSearch() }
        }
    }

    private func closeSearch() {
        search = ""
        filter = nil
        searchActive = false
        searchFocused = false
    }

    private var filterMenu: some View {
        let people = store.frequentPeople()
        let companies = store.frequentCompanies()
        return Menu {
            if people.isEmpty && companies.isEmpty {
                Text("Turn on the calendar to filter by person and company.")
            }
            if !people.isEmpty {
                Section("People") {
                    ForEach(people, id: \.self) { name in Button(name) { filter = .person(name) } }
                }
            }
            if !companies.isEmpty {
                Section("Companies") {
                    ForEach(companies, id: \.self) { domain in Button(domain) { filter = .company(domain) } }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12))
                .foregroundStyle(filter == nil ? Palette.inkSecondary : Palette.ink)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by person or company")
    }

    // MARK: - Meetings

    private struct DayGroup: Identifiable {
        let day: Date
        var meetings: [Meeting]
        var id: Date { day }
    }

    /// Grouped by calendar day. Keyed on the day's start rather than on a
    /// formatted string, so the formatting happens once per group instead of
    /// once per meeting on every render.
    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var result: [DayGroup] = []
        for meeting in store.search(search) {
            if let folder, meeting.folder != folder { continue }
            if let filter, !filter.matches(meeting) { continue }
            let day = calendar.startOfDay(for: meeting.startedAt)
            if result.last?.day == day {
                result[result.count - 1].meetings.append(meeting)
            } else {
                result.append(DayGroup(day: day, meetings: [meeting]))
            }
        }
        return result
    }

    @ViewBuilder
    private var meetingList: some View {
        let groups = self.groups
        if groups.isEmpty {
            Text(isSearching ? "No meetings match." : (folder == nil
                 ? "Your meetings will appear here. Join a call, or start a new note."
                 : "Nothing in this folder yet."))
                .font(.system(size: 14))
                .foregroundStyle(Palette.inkTertiary)
                .padding(.horizontal, 10)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    Text(Formats.day(group.day))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.top, group.id == groups.first?.id ? 0 : 22)
                        .padding(.bottom, 6)
                    ForEach(group.meetings) { meeting in
                        row(meeting)
                    }
                }
            }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        Button { selection = .meeting(meeting.id) } label: {
            MeetingListRow(meeting: meeting,
                           isRecording: coordinator.activeMeetingID == meeting.id && coordinator.phase.isRecording,
                           isProcessing: coordinator.processing[meeting.id] != nil)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.directory])
            }
            if meeting.summaryMarkdown != nil {
                Button(meeting.summaryEditedAt == nil
                       ? "Regenerate notes" : "Regenerate notes, replacing your edits") {
                    Task { await coordinator.summarize(meetingID: meeting.id) }
                }
            }
            FolderMenu(meeting: meeting) {
                newFolderName = ""
                newFolderFor = meeting
            }
            Divider()
            // Not while it is recording or processing: the pipeline would be
            // writing into a folder that no longer exists.
            Button("Delete…", role: .destructive) { pendingDelete = meeting }
                .disabled(coordinator.activeMeetingID == meeting.id
                          || coordinator.processing[meeting.id] != nil)
        }
    }
}

/// "Move to Folder", shared by the Home list and a meeting's folder chip.
struct FolderMenu: View {
    let meeting: Meeting
    var title = "Move to Folder"
    let onNewFolder: () -> Void
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        Menu(title) { FolderMenuItems(meeting: meeting, onNewFolder: onNewFolder) }
    }
}

struct FolderMenuItems: View {
    let meeting: Meeting
    let onNewFolder: () -> Void
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        ForEach(store.folders.filter { $0 != meeting.folder }, id: \.self) { folder in
            Button(folder) { store.update(id: meeting.id) { $0.folder = folder } }
        }
        if !store.folders.isEmpty { Divider() }
        Button("New Folder…", action: onNewFolder)
        if let current = meeting.folder {
            Button("Remove from \(current)") {
                store.update(id: meeting.id) { $0.folder = nil }
            }
        }
    }
}

/// One meeting in a list: a tile, the title, who was there, and the time.
private struct MeetingListRow: View {
    let meeting: Meeting
    let isRecording: Bool
    let isProcessing: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 14) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle)
                    .font(Typeface.listTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typeface.listSubtitle)
                    .foregroundStyle(Palette.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            status
            Text(Formats.time(meeting.startedAt))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.inkTertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(isHovering ? Palette.fill.opacity(0.7) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onHover { isHovering = $0 }
    }

    /// People first — "Caleb, Chris & 12 others" — because who you met is
    /// how most meetings are remembered. Without invitees, where and how long.
    private var subtitle: String {
        let people = meeting.attendees.map(Self.shortName).filter { !$0.isEmpty }
        if !people.isEmpty {
            switch people.count {
            case 1: return people[0]
            case 2: return "\(people[0]) & \(people[1])"
            default: return "\(people[0]), \(people[1]) & \(people.count - 2) other\(people.count == 3 ? "" : "s")"
            }
        }
        return [meeting.detectedAppName, meeting.durationLabel].compactMap { $0 }.joined(separator: " · ")
    }

    private static func shortName(_ attendee: String) -> String {
        let trimmed = attendee.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return String(trimmed.prefix { $0 != "@" }) }
        return String(trimmed.split(separator: " ").first ?? "")
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isRecording ? Palette.recording.opacity(0.12) : Palette.fill)
            if isRecording {
                Circle().fill(Palette.recording).frame(width: 9, height: 9)
            } else if let initial = meeting.attendees.first.flatMap(\.first) {
                Text(String(initial).uppercased())
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(width: 34, height: 34)
    }

    @ViewBuilder
    private var status: some View {
        if isProcessing {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
        } else if meeting.state == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Palette.warning)
                .help(meeting.failureReason ?? "Processing failed")
        }
    }
}

// MARK: - Coming up

/// Today and tomorrow from the calendar, in a card at the top of Home.
private struct ComingUpCard: View {
    @ObservedObject var reminders: MeetingReminders
    @Binding var selection: SidebarItem?
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openSettings) private var openSettings

    private struct Day: Identifiable {
        let date: Date
        let events: [CalendarService.Upcoming]
        var id: Date { date }
    }

    /// Today always — an empty today is worth saying — and tomorrow when it
    /// has something on it.
    private var days: [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let todays = reminders.upcoming.filter { calendar.isDate($0.start, inSameDayAs: today) || $0.start < today }
        let tomorrows = reminders.upcoming.filter { calendar.isDate($0.start, inSameDayAs: tomorrow) }
        var days = [Day(date: today, events: todays)]
        if !tomorrows.isEmpty { days.append(Day(date: tomorrow, events: tomorrows)) }
        return days
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                if index > 0 {
                    Line()
                        .stroke(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(height: 1)
                }
                HStack(alignment: .top, spacing: 0) {
                    DayBadge(date: day.date)
                        .frame(width: 128, alignment: .leading)
                    VStack(alignment: .leading, spacing: 14) {
                        if day.events.isEmpty {
                            emptyDay(isToday: index == 0)
                        } else {
                            ForEach(day.events) { event in
                                EventRow(event: event, selection: $selection)
                            }
                        }
                    }
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.raised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func emptyDay(isToday: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            EventBar(color: Palette.hairline)
            if settings.calendarEnabled, CalendarService.access != .granted {
                // On in Settings, but macOS has not let us read it — the state
                // that made the calendar look empty rather than broken.
                VStack(alignment: .leading, spacing: 8) {
                    Text(CalendarService.access == .denied
                         ? "Calendar access is turned off for Minutes in System Settings."
                         : "Minutes needs your permission to read your calendar.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: CalendarService.access == .denied ? "Open System Settings" : "Allow access",
                               symbol: "calendar") { fixAccess() }
                }
            } else if settings.calendarEnabled, isToday, !CalendarService.shared.hasExchangeAccount {
                // The calendar is on and readable, but holds no work account —
                // the usual case with new Outlook, which keeps its calendar to
                // itself. "No more events today" would be a confident wrong answer.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Outlook calendar isn't on this Mac yet. Add your Microsoft 365 account to macOS, with only Calendars on, and its meetings appear here.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Open Internet Accounts", symbol: "person.crop.circle.badge.plus") {
                        NSWorkspace.shared.open(CalendarService.internetAccountsURL)
                    }
                }
            } else if settings.calendarEnabled {
                Text(isToday ? "No more events today" : "No events")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.inkSecondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Turn on your calendar to see what's next and record it in one click.")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "Use my calendar", symbol: "calendar") { openSettings() }
                }
            }
        }
        .frame(minHeight: 38)
    }

    private func fixAccess() {
        if CalendarService.access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Task {
            await CalendarService.shared.requestAccess()
            coordinator.calendarSettingChanged()
        }
    }
}

private struct DayBadge: View {
    let date: Date

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: 30, weight: .regular, design: .serif))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(date.formatted(.dateTime.month(.wide)))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    if Calendar.current.isDateInToday(date) {
                        Circle().fill(Palette.recording).frame(width: 5, height: 5)
                    }
                }
                Text(date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarService.Upcoming
    @Binding var selection: SidebarItem?
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var chat: ChatController
    @State private var isHovering = false

    var body: some View {
        let live = event.start <= Date()
        HStack(alignment: .center, spacing: 12) {
            EventBar(color: live ? Palette.recording : Palette.speakerOther)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(live ? "Now · \(Formats.timeRange(event.start, event.end))"
                          : Formats.timeRange(event.start, event.end))
                    .font(.system(size: 12.5))
                    .foregroundStyle(live ? Palette.recording : Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            // Actions appear under the pointer only; the card is for reading.
            HStack(spacing: 2) {
                IconButton(symbol: "text.page.badge.magnifyingglass",
                           help: "Brief me: what happened last time and what is still open",
                           emphasis: .plain, size: 12) {
                    selection = .chat
                    chat.send(event.briefPrompt)
                }
                .disabled(chat.isResponding)
                if !coordinator.phase.isRecording {
                    IconButton(symbol: "record.circle",
                               help: event.meetingLink == nil ? "Record this meeting" : "Join the call and record it",
                               emphasis: .plain, tint: Palette.recording, size: 13) {
                        coordinator.joinAndRecord(title: event.title, link: event.meetingLink)
                    }
                }
            }
            .opacity(isHovering || live ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

private struct EventBar: View {
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(color)
            .frame(width: 3, height: 38)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
