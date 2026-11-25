import SwiftUI
import AppKit

/// Notification setup has to wait until AppKit has finished launching.
/// Asking from `App.init()` fails outright with "Notifications are not allowed
/// for this application", because the bundle is not registered with the
/// notification centre that early.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registers the Record / Ignore category, installs the response
        // delegate, and asks for permission — in that order, because a category
        // must exist before a notification referencing it is posted.
        DockPresence.apply(showInDock: AppSettings.shared.showInDock)
        NotificationPresenter.configure()

        // The MenuBarExtra status item is created as the scene is built, a moment
        // after launch, so this check waits for it before reporting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MeetingPromptPanel.shared.logAnchorState()
        }
    }

    /// Quitting mid-meeting used to drop the speaker-label energy track and the
    /// live transcript, which are only written when a recording stops. So stop
    /// it properly first. The pipeline is left for the next launch rather than
    /// holding the quit for minutes of Whisper.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Shell.cancelAll()
        guard let coordinator = RecordingCoordinator.current, coordinator.phase.isRecording else {
            return .terminateNow
        }
        Task { @MainActor in
            await coordinator.stopRecording(startPipeline: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: MeetingStore
    @StateObject private var coordinator: RecordingCoordinator
    @StateObject private var chat: ChatController
    @StateObject private var meetingChats: MeetingChats

    /// Stamped at the top of init — a file-scope `let` would be initialised
    /// lazily on first *use*, which made the launch delta read as zero.
    private static var initStarted = Date()

    init() {
        Self.initStarted = Date()
        AppPaths.ensureDirectories()

        // Diagnostic modes run and exit before any UI is created.
        if Diagnostics.runIfRequested() { exit(0) }

        Log.info("Minutes launching")
        let store = MeetingStore()
        store.prewarmSearchText()
        _store = StateObject(wrappedValue: store)
        _coordinator = StateObject(wrappedValue: RecordingCoordinator(store: store))
        _chat = StateObject(wrappedValue: ChatController(meetings: store))
        _meetingChats = StateObject(wrappedValue: MeetingChats(meetings: store))
    }

    var body: some Scene {
        Window("Minutes", id: "main") {
            MainWindowView()
                .environmentObject(store)
                .environmentObject(coordinator)
                .environmentObject(chat)
                .environmentObject(meetingChats)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    Log.info("Window on screen \(Int(Date().timeIntervalSince(Self.initStarted) * 1000))ms after app init")
                }
        }
        .defaultSize(width: 1180, height: 760)
        // Menu bar only implies no window uninvited — otherwise launching at
        // login throws one on screen. Read once at launch, which is the only
        // moment this matters.
        .defaultLaunchBehavior(AppSettings.shared.showInDock ? .automatic : .suppressed)
        .commands {
            CommandGroup(after: .newItem) {
                Button(coordinator.phase.isRecording ? "Stop Recording" : "Start Recording") {
                    Task {
                        if coordinator.phase.isRecording {
                            await coordinator.stopRecording()
                        } else {
                            await coordinator.startRecording()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(coordinator)
                .environmentObject(chat)
        } label: {
            MenuBarLabel(coordinator: coordinator,
                         activity: coordinator.activity,
                         reminders: coordinator.reminders)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .environmentObject(store)
        }
    }
}
