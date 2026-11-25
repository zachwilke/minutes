import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var chat: ChatController

    @ObservedObject private var settings = AppSettings.shared

    @State private var selection: SidebarItem? = .home
    /// The list a meeting was opened from, which the back button returns to.
    @State private var lastList: SidebarItem = .home
    @State private var search = ""
    @State private var searchRequested = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var setup = SetupService()
    @StateObject private var permissions = PermissionsService()
    @State private var showSetup = false
    @State private var showOnboarding = false
    @State private var onboardingSteps: [OnboardingView.Step] = OnboardingView.Step.permissions

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
                // The system toggle sits in a glass bubble that no modifier
                // removes; a plain one is drawn in the toolbar instead.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                // The page is a shade brighter than the ground the sidebar sits
                // on. That one step is what separates the library from the
                // document without drawing a line between them.
                .background(settings.translucentWindow
                            ? AnyShapeStyle(Palette.surface.opacity(0.82))
                            : AnyShapeStyle(Palette.surface))
        }
        // The window's ground goes behind the whole split view; the sidebar and
        // panes then clear their own backgrounds to let it through.
        .background(WindowBackground(translucent: settings.translucentWindow))
        .tint(Palette.ink)
        .toolbar { toolbarContent }
        // No window title: the page says where you are. A title in the bar
        // only repeated the app's name over every meeting.
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear {
            if selection == nil { selection = .home }
        }
        .onChange(of: selection) { previous, current in
            // A search belongs to the list it was typed in.
            if let previous, let current, previous.isList, current.isList, previous != current {
                search = ""
            }
            if let current, current.isList { lastList = current }
        }
        // Jump to whatever is being recorded or processed, so the notes pane is
        // in front of you the moment a meeting starts.
        .onChange(of: coordinator.activeMeetingID) { _, newValue in
            if let newValue { selection = .meeting(newValue) }
        }
        .onChange(of: coordinator.requestedMeetingID) { _, _ in consumeRequests() }
        .onChange(of: coordinator.requestedSidebarItem) { _, _ in consumeRequests() }
        // A request made from the menu bar while the window was closed is
        // already set when it opens, so onChange alone never saw it.
        .onAppear { consumeRequests() }
        .overlay(alignment: .bottom) { banner }
        .sheet(isPresented: $showSetup) {
            SetupView(setup: setup) { showSetup = false }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(permissions: permissions,
                           permissionSteps: onboardingSteps,
                           isUpdate: AppSettings.shared.hasCompletedOnboarding) {
                AppSettings.shared.hasCompletedOnboarding = true
                // Asked once, whatever the answer: skipped ones live in Settings.
                AppSettings.shared.permissionsAsked.formUnion(onboardingSteps.map(\.rawValue))
                showOnboarding = false
                // Dependencies come after permissions, and only if needed.
                if setup.needsSetup { showSetup = true }
            }
            .interactiveDismissDisabled()
        }
        .task {
            await setup.refresh()
            permissions.refresh()
            // Notification state arrives asynchronously.
            try? await Task.sleep(for: .milliseconds(400))
            Log.info("Permissions at launch: mic=\(permissions.microphone.label) notifications=\(permissions.notifications.label) "
                     + "accessibility=\(permissions.accessibility.label) calendar=\(permissions.calendar.label) "
                     + "onboarded=\(AppSettings.shared.hasCompletedOnboarding) "
                     + "asking=\(OnboardingView.missingSteps(permissions).map(\.rawValue))")
            if !AppSettings.shared.hasCompletedOnboarding {
                // First launch: permissions walkthrough first; the dependency
                // sheet chains after it if anything is missing.
                onboardingSteps = OnboardingView.Step.permissions
                showOnboarding = true
            } else if case let missing = OnboardingView.missingSteps(permissions), !missing.isEmpty {
                // An update added a permission, or one was never granted:
                // ask about just those, once.
                onboardingSteps = missing
                showOnboarding = true
            } else if setup.needsSetup {
                // Offer setup before the first failed meeting does it the hard way.
                showSetup = true
            }
            // Calendar switched on, but macOS was never asked: every calendar
            // feature then does nothing, silently — no names, no Coming up, and
            // no telling a scheduled call from an impromptu one. Ask now.
            if AppSettings.shared.hasCompletedOnboarding, AppSettings.shared.calendarEnabled,
               CalendarService.access == .notAsked {
                Log.info("Calendar is on but access was never requested; asking")
                await CalendarService.shared.requestAccess()
                coordinator.calendarSettingChanged()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home, nil:
            HomeView(selection: $selection, search: $search, searchRequested: $searchRequested)
        case .folder(let name):
            HomeView(selection: $selection, folder: name, search: $search, searchRequested: $searchRequested)
                .id(name)
        case .chat:
            ChatView(chat: chat)
        case .meeting(let id) where store.meeting(id: id) != nil:
            MeetingDetailView(meetingID: id)
        case .trash:
            TrashView()
        case .meeting:
            // Deleted out from under the selection.
            EmptyState()
        }
    }

    /// Shows whatever the menu bar asked for. Consumed — cleared so tapping the
    /// same row again still works.
    private func consumeRequests() {
        if let requested = coordinator.requestedMeetingID {
            selection = .meeting(requested)
            coordinator.requestedMeetingID = nil
        }
        if let item = coordinator.requestedSidebarItem {
            selection = item
            coordinator.requestedSidebarItem = nil
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ToolbarIcon(symbol: "sidebar.left",
                        help: columnVisibility == .detailOnly ? "Show the sidebar" : "Hide the sidebar") {
                withAnimation(.easeOut(duration: 0.18)) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
            ToolbarIcon(symbol: "magnifyingglass", help: "Search meetings") {
                if !(selection?.isList ?? false) { selection = lastList }
                searchRequested = true
            }
            .keyboardShortcut("f", modifiers: .command)
            if case .meeting = selection {
                ToolbarIcon(symbol: "chevron.left",
                            help: lastList == .home ? "Back to Home" : "Back") {
                    selection = lastList
                }
                .keyboardShortcut("[", modifiers: .command)
            }
        }
        // macOS wraps toolbar items in a shared glass capsule. These draw their
        // own hover fill, so that capsule is a second, unwanted shape.
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .primaryAction) {
            NewNoteButton(coordinator: coordinator, activity: coordinator.activity)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    /// Transient messages: non-fatal warnings and pipeline failures.
    @ViewBuilder
    private var banner: some View {
        if case .failed(let reason) = coordinator.phase {
            BannerView(icon: "exclamationmark.triangle.fill",
                       tint: Palette.danger,
                       message: reason) { coordinator.clearFailure() }
        } else if let warning = coordinator.warning {
            BannerView(icon: "info.circle.fill",
                       tint: Palette.warning,
                       message: warning) { coordinator.clearFailure() }
        }
    }
}

private struct BannerView: View {
    let icon: String
    let tint: Color
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(message)
                .font(Typeface.label)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            IconButton(symbol: "xmark", help: "Dismiss", emphasis: .plain, size: 10) { dismiss() }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .floatingCard()
        .padding(18)
    }
}

/// Nothing selected. Granola's version of this screen is an invitation rather
/// than a shrug, so this one names the next thing to do and puts the control
/// for it under your pointer.
private struct EmptyState: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.inkTertiary)

            VStack(spacing: 6) {
                Text(store.meetings.isEmpty ? "No meetings yet" : "Nothing selected")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(AppSettings.shared.autoDetectMeetings
                     ? "Minutes is watching for calls. Join one and it starts by itself, or record now."
                     : "Press record to start capturing, or turn on meeting detection in Settings.")
                    .font(Typeface.label)
                    .foregroundStyle(Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }

            PillButton(title: "Record a meeting", symbol: "record.circle", prominent: true) {
                Task { await coordinator.startRecording() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A plain glyph in the titlebar that fills on hover. The system's toolbar
/// buttons draw a glass bubble each; Granola's titlebar has none.
private struct ToolbarIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isHovering ? Palette.ink : Palette.inkSecondary)
                .frame(width: 30, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(isHovering ? Palette.fill : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// "+ New note", or — while recording — the clock and Stop.
///
/// A new note in Minutes is a recording: the page opens and capture starts, the
/// same as joining a call would. So the one primary control in the window is
/// named for what you get, and turns into the way to end it.
private struct NewNoteButton: View {
    @ObservedObject var coordinator: RecordingCoordinator
    @ObservedObject var activity: RecordingActivity
    @State private var isHovering = false

    var body: some View {
        let recording = coordinator.phase.isRecording
        Button {
            Task {
                if recording { await coordinator.stopRecording() } else { await coordinator.startRecording() }
            }
        } label: {
            HStack(spacing: 6) {
                if recording {
                    Circle().fill(Palette.recording).frame(width: 7, height: 7)
                    Text(MenuBarView.timeLabel(activity.elapsed))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.ink)
                    Text("Stop")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.recording)
                } else {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text("New note").font(.system(size: 13.5))
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background {
                Capsule().fill(recording ? Palette.recording.opacity(isHovering ? 0.16 : 0.10)
                                         : (isHovering ? Palette.fill : Palette.raised))
            }
            .overlay {
                Capsule().strokeBorder(recording ? Palette.recording.opacity(0.35) : Palette.hairline,
                                       lineWidth: 0.75)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(recording ? "Stop recording and write notes" : "Start a new note and record (⇧⌘R)")
        .accessibilityLabel(recording ? "Stop recording" : "New note")
    }
}
