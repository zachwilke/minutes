import SwiftUI
import EventKit
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var customTemplates = CustomTemplates.shared
    /// The style being created or edited in the sheet.
    @State private var editingTemplate: CustomTemplates.Entry?
    @StateObject private var permissions = PermissionsService()
    @StateObject private var claude = ClaudeConnection()

    var body: some View {
        TabView {
            appearance.tabItem { Label("Appearance", systemImage: "paintpalette") }
            general.tabItem { Label("General", systemImage: "gearshape") }
            transcription.tabItem { Label("Transcription", systemImage: "waveform") }
            notesTab.tabItem { Label("Notes", systemImage: "sparkles") }
            ClaudeTab().tabItem { Label("Claude", systemImage: "bubble.left.and.text.bubble.right") }
        }
        .frame(width: 520)
        .padding(20)
        .tint(Palette.accent)
        .sheet(item: $editingTemplate) { entry in
            TemplateEditor(entry: entry,
                           isNew: !customTemplates.entries.contains { $0.id == entry.id },
                           onSave: { customTemplates.save($0); editingTemplate = nil },
                           onDelete: { customTemplates.delete($0); editingTemplate = nil },
                           onCancel: { editingTemplate = nil })
        }
    }

    // MARK: - Appearance

    private var appearance: some View {
        Form {
            Section("Window") {
                Toggle("Translucent, blurred window", isOn: bind(\.translucentWindow))
                Text("Blurs whatever sits behind the window and washes it with a little brand green. Switch it off for a solid background — easier to read against a busy desktop, and lighter on an older Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Menu bar") {
                Toggle("Show the recording clock and next meeting", isOn: bind(\.menuBarText))
                Text("Beside the menu bar icon: the elapsed time while recording, or the next calendar meeting when it starts within 15 minutes. Off shows the icon alone.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Dock") {
                Toggle("Keep an icon in the Dock", isOn: Binding(
                    get: { settings.showInDock },
                    set: { newValue in
                        settings.showInDock = newValue
                        DockPresence.apply(showInDock: newValue)
                    }))
                Text("Turn this off to run from the menu bar alone. The window still opens from the menu bar icon, and it no longer appears on launch. Takes effect immediately.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Preview") {
                // Shows both treatments side by side, so the choice can be made
                // by looking rather than by toggling and hunting for a window.
                HStack(spacing: 12) {
                    swatch(translucent: true, label: "Translucent")
                    swatch(translucent: false, label: "Solid")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }

            Section("Colour") {
                HStack(spacing: 10) {
                    ForEach(Array(swatchColors.enumerated()), id: \.offset) { _, entry in
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .fill(entry.color)
                                .frame(width: 40, height: 26)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                        .strokeBorder(Palette.hairline, lineWidth: 0.5)
                                }
                            Text(entry.name)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Warm paper and ink. Colour is spent only where it carries something shape and weight cannot: red while recording, amber on a warning. There is no theme to choose — this is a page of notes, and a page of notes has one.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var swatchColors: [(name: String, color: Color)] {
        [("Paper", Palette.paper),
         ("Page", Palette.surface),
         ("Ink", Palette.ink),
         ("Recording", Palette.recording)]
    }

    private func swatch(translucent: Bool, label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                BrandBackground(translucent: translucent)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Palette.ink.opacity(0.8)).frame(width: 46, height: 5)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Palette.inkSecondary.opacity(0.45)).frame(width: 66, height: 4)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Palette.inkSecondary.opacity(0.30)).frame(width: 54, height: 4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 74)
            .clipShape(.rect(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(settings.translucentWindow == translucent
                                  ? Palette.ink : Palette.hairline,
                                  lineWidth: settings.translucentWindow == translucent ? 2 : 0.5)
            }
            Text(label)
                .font(.system(size: 10, weight: settings.translucentWindow == translucent ? .semibold : .regular))
                .foregroundStyle(settings.translucentWindow == translucent ? Palette.ink : Palette.inkSecondary)
        }
        .onTapGesture { settings.translucentWindow = translucent }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Permissions") {
                microphoneRow
                systemAudioRow
                notificationRow
                calendarRow
                accessibilityRow
            }

            Section {
                Toggle("Watch for meetings automatically", isOn: Binding(
                    get: { settings.autoDetectMeetings },
                    set: { coordinator.setDetectionEnabled($0) }))
                Picker("When a call starts", selection: Binding(
                    get: { settings.detectionMode },
                    set: { settings.detectionMode = $0 })) {
                    Text("Record calendar meetings, offer the rest").tag(DetectionMode.autoRecord)
                    Text("Ask first").tag(DetectionMode.ask)
                }
                .disabled(!settings.autoDetectMeetings)
                Text(detectionModeDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    IconButton(symbol: "eye",
                                help: "Show the prompt where a real one appears, under the menu bar icon (its buttons don't record)") {
                        MeetingPromptPanel.shared.show(
                            appName: "Microsoft Teams",
                            ambiguous: false,
                            onRecord: { MeetingPromptPanel.shared.hide() },
                            onIgnore: { MeetingPromptPanel.shared.hide() })
                    }
                    Text("Preview the prompt")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Capture") {
                Toggle("Microphone (your voice, in-person meetings)", isOn: bind(\.captureMicrophone))
                Toggle("System audio (everyone on the call)", isOn: bind(\.captureSystemAudio))
                Toggle("Name calls from the meeting window", isOn: bind(\.nameFromCallWindow))
                Toggle("Cancel speaker echo from the microphone", isOn: bind(\.echoCancellation))
                Text("On speakers rather than headphones, the microphone also hears the call — so “You” moves while you are silent and speaker labels blur. This removes what the Mac is playing from the microphone, as FaceTime does. Applies from the next recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You keep hearing the meeting normally while it records.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Calendar") {
                Toggle("Use my calendar", isOn: Binding(
                    get: { settings.calendarEnabled },
                    set: { newValue in
                        settings.calendarEnabled = newValue
                        Task {
                            if newValue { await CalendarService.shared.requestAccess() }
                            coordinator.calendarSettingChanged()
                        }
                    }))
                Toggle("Remind me a minute before meetings", isOn: bind(\.meetingReminders))
                    .disabled(!settings.calendarEnabled)
                if settings.calendarEnabled {
                    CalendarPicker { coordinator.calendarSettingChanged() }
                }
                Text("Off by default. Turning it on asks for Calendar access. Recordings are named after the event and pick up its invitees, upcoming meetings appear in the sidebar, and the reminder's Join & Record opens the call link and starts recording. Browser calls during an event with a meeting link record automatically. Events you declined, and ones with no invitees and no link, are ignored.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Files") {
                HStack(spacing: 6) {
                    IconButton(symbol: "folder",
                                help: "Open the meetings library folder") {
                        NSWorkspace.shared.open(AppPaths.meetingsRoot)
                    }
                    IconButton(symbol: "doc.text.magnifyingglass",
                                help: "Open the logs folder") {
                        NSWorkspace.shared.open(AppPaths.logsRoot)
                    }
                }
                Text(AppPaths.supportRoot.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Transcription

    private var transcription: some View {
        Form {
            Section("Language") {
                Picker("Meetings are in", selection: bind(\.transcriptionLanguage)) {
                    Text("Detect automatically").tag("auto")
                    Divider()
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Write notes in", selection: bind(\.notesLanguage)) {
                    Text("The meeting's language").tag("")
                    Divider()
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.name) }
                }
                Text("Detection works for mixed teams; a fixed language is more accurate when every meeting is in it. Notes can be written in a different language from the meeting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Keeping recordings") {
                Picker("Delete audio after", selection: Binding(
                    get: { settings.audioRetentionDays },
                    set: { settings.audioRetentionDays = $0; store.applyAudioRetention() })) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Older recordings lose their audio; the transcript, your notes and the summary stay. Deleted meetings are kept in Recently Deleted for 30 days.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Whisper model") {
                if let model = WhisperRefiner.preferredModel() {
                    LabeledContent("In use") {
                        Text(model.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No model found. Run Scripts/fetch-model.sh, or drop a ggml-*.bin file into the Models folder.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 6) {
                    IconButton(symbol: "doc.badge.gearshape",
                                help: "Choose a specific model file…") { chooseModel() }
                    if settings.whisperModelPath != nil {
                        IconButton(symbol: "wand.and.stars",
                                    help: "Go back to picking the best model automatically") {
                            settings.whisperModelPath = nil
                        }
                    }
                    IconButton(symbol: "folder",
                                help: "Open the Models folder") {
                        NSWorkspace.shared.open(AppPaths.modelsRoot)
                    }
                }
                Text("Larger models are more accurate and slower. large-v3-turbo is the best trade-off on Apple silicon.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Tools") {
                LabeledContent("whisper-cli") {
                    Text(ToolLocator.find("whisper-cli")?.path ?? "Not found — brew install whisper-cpp")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ToolLocator.find("whisper-cli") == nil ? .orange : .secondary)
                }
                Text("The Claude connection is shown on the Notes tab.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Live text during the meeting comes from Apple's on-device transcriber. The saved transcript is re-done with Whisper when you stop, which is slower but markedly more accurate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notes

    private var notesTab: some View {
        Form {
            Section("You") {
                TextField("Your name", text: bind(\.myName))
                Text("You're \"You\" in every transcript. Claude is told this name, and who was invited, so notes say who said and agreed to what. Taken from your Mac account; change it here if that isn't how colleagues know you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Claude") {
                claudeStatusRow
                Picker("Model", selection: bind(\.claudeModel)) {
                    Text("Sonnet — fast, strong default").tag("sonnet")
                    Text("Opus — best quality, slower").tag("opus")
                    Text("Haiku — fastest, lightest").tag("haiku")
                }
                Text("Runs through the `claude` CLI, so this uses your Claude subscription. No API key, no per-token billing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                Toggle("Write notes automatically when a meeting ends", isOn: bind(\.autoSummarize))
                Picker("Default style", selection: bind(\.defaultTemplateID)) {
                    ForEach(SummaryTemplate.all) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                Text(SummaryTemplate.named(settings.defaultTemplateID).blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ForEach(customTemplates.entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.system(size: 12, weight: .medium))
                            if !entry.blurb.isEmpty {
                                Text(entry.blurb).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Edit…") { editingTemplate = entry }
                    }
                }
                Button("New style…") {
                    editingTemplate = CustomTemplates.Entry(
                        name: "",
                        instructions: SummaryTemplate.named("general").instructions)
                }
                Text("Your own styles appear alongside the built-in ones. Describe the sections you want; your notes and the transcript are supplied around it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                LabeledContent("Skip meetings under") {
                    HStack(spacing: 6) {
                        Stepper(value: bind(\.minimumMeetingSeconds), in: 0...600, step: 15) {
                            Text("\(Int(settings.minimumMeetingSeconds))s")
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Only the token-free check runs on its own. Proving the model
            // answers spends the user's quota, so that stays behind the button.
            if claude.state == .unknown { await claude.refresh() }
        }
    }

    // MARK: - Claude connection

    private var claudeStatusRow: some View {
        PermissionRow(title: "Connection",
                      detail: claudeDetail,
                      badge: claudeBadge) {
            IconButton(symbol: "arrow.clockwise",
                        help: "Re-check the connection (no tokens used)") {
                Task { await claude.refresh() }
            }
            .disabled(claude.state == .checking)

            IconButton(symbol: "paperplane",
                        help: "Send a one-word prompt to prove the model answers (uses a few tokens)",
                        emphasis: .prominent) {
                Task { await claude.verify() }
            }
            .disabled(claude.state == .checking || claude.state == .notFound)
        }
    }

    private var claudeDetail: String {
        switch claude.state {
        case .unknown:
            return "Not checked yet."
        case .checking:
            return "Checking…"
        case .notFound:
            return "The claude CLI was not found. Install Claude Code, sign in, and re-check."
        case .signedOut:
            return "The CLI is installed but nobody is signed in. Run `claude auth login` in a terminal, then re-check."
        case .signedIn(let account):
            var parts = ["Signed in"]
            if let email = account.email { parts.append("as \(email)") }
            if !account.summary.isEmpty { parts.append("— \(account.summary)") }
            return parts.joined(separator: " ")
                + ". Send a test prompt to confirm the model answers."
        case .verified(let account, let latency):
            var parts = ["Working"]
            if let email = account.email { parts.append("— \(email)") }
            if !account.summary.isEmpty { parts.append("(\(account.summary))") }
            return parts.joined(separator: " ")
                + String(format: ". Replied in %.1fs on %@.", latency, AppSettings.shared.claudeModel)
        case .failed(let reason):
            return reason
        }
    }

    private var claudeBadge: (text: String, color: Color)? {
        switch claude.state {
        case .unknown: return nil
        case .checking: return ("Checking", .secondary)
        case .notFound: return ("Not found", Palette.warning)
        case .signedOut: return ("Signed out", Palette.warning)
        case .signedIn: return ("Signed in", Palette.speakerOther)
        case .verified: return ("Working", Palette.accent)
        case .failed: return ("Failed", Palette.danger)
        }
    }

    // MARK: - Permission rows

    private var microphoneRow: some View {
        PermissionRow(title: "Microphone",
                      detail: microphoneDetail,
                      badge: badge(for: permissions.microphone)) {
            if permissions.microphone == .notDetermined {
                IconButton(symbol: "lock.open",
                            help: permissions.isRequestingMicrophone
                                ? "Waiting for your answer…"
                                : "Ask macOS for microphone access",
                            emphasis: .prominent) {
                    Task { await permissions.requestMicrophone() }
                }
                .disabled(permissions.isRequestingMicrophone)
            } else {
                IconButton(symbol: "gearshape",
                            help: "Open System Settings › Privacy & Security › Microphone") {
                    permissions.openMicrophoneSettings()
                }
                if permissions.microphone == .denied {
                    // An ad-hoc rebuild can leave a stale denial behind, with no
                    // row in System Settings to switch on.
                    IconButton(symbol: "arrow.counterclockwise",
                                help: "Reset the decision and ask again") {
                        Task { await permissions.resetMicrophoneDecision() }
                    }
                }
            }
        }
    }

    private var systemAudioRow: some View {
        PermissionRow(title: "System audio",
                      detail: systemAudioDetail,
                      badge: systemAudioBadge) {
            IconButton(symbol: "play.circle",
                        help: permissions.systemAudio == .testing
                            ? "Listening…"
                            : "Play a sound and check that the tap hears it",
                        emphasis: .prominent) {
                Task { await permissions.checkSystemAudio() }
            }
            .disabled(permissions.systemAudio == .testing)

            IconButton(symbol: "gearshape",
                        help: "Open System Settings › Privacy & Security › Audio Recording") {
                permissions.openAudioCaptureSettings()
            }
        }
    }

    private var notificationRow: some View {
        PermissionRow(title: "Notifications",
                      detail: notificationDetail,
                      badge: badge(for: permissions.notifications)) {
            IconButton(symbol: "gearshape",
                        help: "Open System Settings › Notifications") {
                NotificationPresenter.openSystemSettings()
            }
        }
    }

    private var detectionModeDetail: String {
        switch settings.detectionMode {
        case .autoRecord:
            return "A call during a meeting on your calendar records by itself, with Stop and Discard on the notice. A call that isn't on your calendar is offered, with Record and Ignore. Without calendar access every call is offered. Recording stops when the call ends, after 15 minutes of silence, or when the Mac sleeps. Let people know you're recording — some places require everyone's consent."
        case .ask:
            return "Detects when Zoom, Teams, Meet, Webex, Slack and similar start using your microphone, then asks whether to record. Nothing is captured until you say yes. Recording stops when the call ends, after 15 minutes of silence, or when the Mac sleeps."
        }
    }

    /// Worth spelling out that the feature still works without this, because the
    /// obvious assumption is that a denied notification means no prompt at all.
    private var notificationDetail: String {
        switch permissions.notifications {
        case .granted:
            return "Detected calls show a banner: Record and Ignore when asking, Stop and Discard when recording automatically."
        case .notDetermined:
            return "Used to ask whether to record when a call is detected."
        case .denied:
            return "Banners are blocked, so detected calls prompt with a floating window near the menu bar instead. Enable notifications for a less intrusive prompt."
        }
    }

    /// Accessibility is the only way to read a meeting window's title. macOS
    /// adds the app to the list on the first request; the user then switches
    /// it on there, and the change is picked up when the app comes forward.
    private var accessibilityRow: some View {
        PermissionRow(title: "Accessibility",
                      detail: permissions.accessibility == .granted
                        ? "Names calls from the Teams or Webex window when the calendar has no event."
                        : "Optional. Lets recordings be named after the Teams or Webex call instead of “Microsoft Teams call, 10:02”. Only window titles are read.",
                      badge: badge(for: permissions.accessibility)) {
            if permissions.accessibility != .granted {
                IconButton(symbol: "lock.open",
                           help: "Add Minutes to Accessibility, then switch it on in System Settings") {
                    CallWindowTitle.requestAccess()
                    permissions.openAccessibilitySettings()
                }
            }
        }
    }

    private var calendarRow: some View {
        PermissionRow(title: "Calendar",
                      detail: settings.calendarEnabled
                        ? "Names recordings, lists upcoming meetings, and reminds you before they start."
                        : "Not in use. Turn on Use my calendar below to request it.",
                      badge: settings.calendarEnabled ? badge(for: permissions.calendar) : nil) {
            if settings.calendarEnabled, permissions.calendar == .notDetermined {
                IconButton(symbol: "lock.open",
                            help: "Ask macOS for calendar access") {
                    Task {
                        await CalendarService.shared.requestAccess()
                        permissions.refresh()
                        coordinator.calendarSettingChanged()
                    }
                }
            } else if settings.calendarEnabled {
                IconButton(symbol: "gearshape",
                            help: "Open System Settings › Privacy & Security › Calendars") {
                    permissions.openCalendarSettings()
                }
            }
        }
    }

    private var microphoneDetail: String {
        if let hint = permissions.resetHint { return hint }
        switch permissions.microphone {
        case .granted:
            return "Records your voice, and the room in an in-person meeting."
        case .notDetermined:
            return "Records your voice, and the room in an in-person meeting. macOS will ask once."
        case .denied:
            return "Until this is enabled, recordings capture only the far end of a call. If Minutes is not listed in System Settings, use Reset & ask again."
        }
    }

    /// Deliberately explicit about the silence case: a recording that looks fine
    /// but contains nothing is the single most confusing failure here.
    private var systemAudioDetail: String {
        switch permissions.systemAudio {
        case .untested:
            return "Captures everyone else on the call. macOS offers no way to read this permission, so run the test: it plays a sound and listens for it."
        case .testing:
            return "Playing a test sound and listening for it…"
        case .working(let peak):
            return String(format: "Working — heard the test sound at peak %.3f.", peak)
        case .silent:
            return "The tap ran but every sample was silent, which is exactly how a missing permission looks. Enable Minutes under Audio Recording, then test again."
        case .noAudio:
            return "No audio arrived at all. Enable Minutes under Audio Recording, then test again."
        case .failed(let reason):
            return reason
        }
    }

    private var systemAudioBadge: (text: String, color: Color)? {
        switch permissions.systemAudio {
        case .untested: return nil
        case .testing: return ("Testing", .secondary)
        case .working: return ("Working", .green)
        case .silent, .noAudio: return ("No audio", .orange)
        case .failed: return ("Failed", .red)
        }
    }

    private func badge(for status: PermissionsService.Status) -> (text: String, color: Color) {
        switch status {
        case .granted: return (status.label, .green)
        case .denied: return (status.label, .orange)
        case .notDetermined: return (status.label, .secondary)
        }
    }

    // MARK: - Helpers

    /// Settings is UserDefaults-backed rather than @Published per property, so
    /// bindings are built by hand.

    /// Whisper language codes with their English names, which double as the
    /// notes-language instruction.
    private static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"),
        ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"),
        ("ru", "Russian"), ("uk", "Ukrainian"), ("tr", "Turkish"), ("ar", "Arabic"),
        ("he", "Hebrew"), ("hi", "Hindi"), ("ja", "Japanese"), ("ko", "Korean"),
        ("zh", "Chinese"), ("vi", "Vietnamese"), ("id", "Indonesian")
    ]

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: keyPath] },
                set: { settings[keyPath: keyPath] = $0 })
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.directoryURL = AppPaths.modelsRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.whisperModelPath = url.path
    }
}

/// One permission: what it is for, where it stands, and what you can do about it.
private struct PermissionRow<Trailing: View>: View {
    let title: String
    let detail: String
    let badge: (text: String, color: Color)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    if let badge {
                        Text(badge.text)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge.color.opacity(0.16), in: Capsule())
                            .foregroundStyle(badge.color)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) { trailing() }
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}


/// Creates or edits one of the user's own summary styles.
private struct TemplateEditor: View {
    @State var entry: CustomTemplates.Entry
    let isNew: Bool
    let onSave: (CustomTemplates.Entry) -> Void
    let onDelete: (CustomTemplates.Entry) -> Void
    let onCancel: () -> Void
    @State private var confirmDelete = false

    private var canSave: Bool {
        !entry.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !entry.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New summary style" : "Edit summary style")
                .font(.system(size: 15, weight: .semibold))
            TextField("Name, e.g. Board meeting", text: $entry.name)
            TextField("One-line description (optional)", text: $entry.blurb)
            Text("What to produce")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $entry.instructions)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 260)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)
                }
            Text("Name the sections and say what goes in each. Markdown headings work best. Claude also receives your notes, the transcript, and the instruction not to invent anything.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(entry) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .confirmationDialog("Delete “\(entry.name)”?", isPresented: $confirmDelete) {
            Button("Delete Style", role: .destructive) { onDelete(entry) }
        } message: {
            Text("Meetings that used it fall back to General the next time they are rewritten.")
        }
    }
}


/// Which calendars count: for Coming up, naming recordings, and telling a
/// scheduled call from an impromptu one. Grouped by the account each syncs
/// from, because "Calendar" alone names one in every account.
private struct CalendarPicker: View {
    let onChange: () -> Void
    @ObservedObject private var settings = AppSettings.shared
    @State private var calendars: [CalendarService.CalendarInfo] = []
    @State private var hasExchange = false

    var body: some View {
        Group {
            ForEach(Dictionary(grouping: calendars, by: \.account).sorted { $0.key < $1.key }, id: \.key) { account, items in
                VStack(alignment: .leading, spacing: 4) {
                    Text(account)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(items) { calendar in
                        Toggle(calendar.title, isOn: Binding(
                            get: { !settings.excludedCalendarIDs.contains(calendar.id) },
                            set: { on in
                                if on { settings.excludedCalendarIDs.remove(calendar.id) }
                                else { settings.excludedCalendarIDs.insert(calendar.id) }
                                onChange()
                            }))
                    }
                }
            }
            if !hasExchange {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Using Outlook? New Outlook keeps its calendar to itself, so Minutes reads it through macOS. Add your Microsoft 365 account in Internet Accounts with only Calendars switched on; it syncs here on its own, and nothing else on the Mac changes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Internet Accounts…") { NSWorkspace.shared.open(CalendarService.internetAccountsURL) }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in reload() }
    }

    private func reload() {
        calendars = CalendarService.shared.calendars()
        hasExchange = CalendarService.shared.hasExchangeAccount
    }
}


/// Connects Claude to the meeting library: Claude Desktop and Claude Code
/// each start Minutes' local MCP server when they need it, and can then
/// search and read your meetings.
private struct ClaudeTab: View {
    @State private var desktop: ClaudeConnectors.Status = ClaudeConnectors.desktopStatus()
    @State private var code: ClaudeConnectors.Status?
    @State private var desktopChanged = false
    @State private var working = false
    @State private var problem: String?
    @State private var test: String?
    @State private var testPassed = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ask Claude about your meetings")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Connect Claude Desktop or Claude Code to Minutes, then ask in any chat: what was decided, who said what, what you promised. Claude starts Minutes on this Mac when it needs it and reads only the passages it asks for. Nothing is uploaded, and it can't change your meetings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            Section("Apps") {
                if desktop != .unavailable {
                    row("Claude Desktop", status: desktop,
                        note: desktopChanged ? "Quit and reopen Claude Desktop to pick up the change." : nil,
                        connect: { change { try ClaudeConnectors.addToDesktop(); desktopChanged = true } },
                        disconnect: { change { try ClaudeConnectors.removeFromDesktop(); desktopChanged = true } })
                }
                if let code {
                    row("Claude Code", status: code, note: nil,
                        connect: { Task { await changeCode { try await ClaudeConnectors.addToCode() } } },
                        disconnect: { Task { await changeCode { try await ClaudeConnectors.removeFromCode() } } })
                } else {
                    LabeledContent("Claude Code") { ProgressView().controlSize(.small) }
                }
                if desktop == .unavailable, code == .unavailable {
                    Text("Neither Claude Desktop nor Claude Code is installed on this Mac.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Check") {
                HStack {
                    Button("Test the connection") { Task { await runTest() } }.disabled(working)
                    if let test {
                        Image(systemName: testPassed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(testPassed ? Color.green : Palette.warning)
                        Text(test).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Starts Minutes' server the way Claude does and lists its tools. Uses none of your Claude plan.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Try asking") {
                ForEach(["What did I promise in last week's meetings?",
                         "What did Marcus and I decide about the VPN groups?",
                         "Brief me on my last three calls with Northwind."], id: \.self) { example in
                    Text("“\(example)”").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            Section("Terminal") {
                HStack {
                    Text(ClaudeConnectors.codeCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer()
                    IconButton(symbol: "doc.on.doc", help: "Copy the Claude Code command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ClaudeConnectors.codeCommand, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { code = await ClaudeConnectors.codeStatus() }
    }

    @ViewBuilder
    private func row(_ name: String, status: ClaudeConnectors.Status, note: String?,
                     connect: @escaping () -> Void, disconnect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(name) {
                HStack(spacing: 8) {
                    switch status {
                    case .connected:
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon).foregroundStyle(.green)
                        Button("Disconnect", action: disconnect).disabled(working)
                    case .otherCopy:
                        Label("Points to another copy", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon).foregroundStyle(Palette.warning)
                        Button("Reconnect", action: connect).disabled(working)
                    case .notConnected:
                        Button("Connect", action: connect).disabled(working)
                    case .unavailable:
                        Text("Not installed").foregroundStyle(.secondary)
                    }
                }
            }
            if case .otherCopy(let path) = status, !path.isEmpty {
                Text("It starts \(path). Reconnect to use this copy of Minutes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        desktop = ClaudeConnectors.desktopStatus()
    }

    private func changeCode(_ action: () async throws -> Void) async {
        working = true
        defer { working = false }
        do {
            try await action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        code = await ClaudeConnectors.codeStatus()
    }

    private func runTest() async {
        working = true
        defer { working = false }
        switch await ClaudeConnectors.selfTest() {
        case .success(let tools):
            testPassed = true
            test = "Working: \(tools.count) tools (\(tools.joined(separator: ", ")))."
        case .failure(let error):
            testPassed = false
            test = error.localizedDescription
        }
    }
}
