import SwiftUI

/// First-launch walkthrough: one permission per page, asked with context.
///
/// Without this, the permissions ambush people — the notification prompt fired
/// the moment the app launched, and the microphone and Audio Recording prompts
/// interrupted the first real meeting. Each page explains what a permission is
/// for *before* raising the system prompt, and shows the live result after.
///
/// Every step is skippable. Permissions stay available under
/// Settings › Permissions, and the app degrades sanely without any of them.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsService
    /// The permission pages to show; the welcome and closing pages are added.
    /// The full set on first launch, only what is new and missing afterwards.
    var permissionSteps: [Step] = Step.permissions
    /// A returning user, being asked only about what is missing.
    var isUpdate = false
    /// Called when the walkthrough finishes or is skipped.
    let finish: () -> Void

    enum Step: String, CaseIterable {
        case welcome
        case microphone
        case systemAudio
        case notifications
        case accessibility
        case calendar
        case done

        static let permissions: [Step] = [.microphone, .systemAudio, .notifications, .accessibility, .calendar]
    }

    /// Permission pages worth showing a returning user: not yet granted, and
    /// never asked about before. System audio has no readable state and was
    /// covered on first launch, so it is not re-asked.
    @MainActor
    static func missingSteps(_ permissions: PermissionsService) -> [Step] {
        let asked = AppSettings.shared.permissionsAsked
        return Step.permissions.filter { step in
            guard !asked.contains(step.rawValue) else { return false }
            switch step {
            case .microphone: return permissions.microphone != .granted
            case .notifications: return permissions.notifications != .granted
            case .accessibility: return permissions.accessibility != .granted
            case .calendar: return !(AppSettings.shared.calendarEnabled && permissions.calendar == .granted)
            default: return false
            }
        }
    }

    private var steps: [Step] { [.welcome] + permissionSteps + [.done] }
    @State private var index = 0
    private var step: Step { steps[min(index, steps.count - 1)] }
    @State private var notificationsAnswered = false
    /// Accessibility changes in System Settings send no notification, so its
    /// page watches for the switch.
    private let accessibilityPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(24)
            footer
        }
        .frame(width: 480, height: 360)
        .background(BrandBackground(translucent: AppSettings.shared.translucentWindow))
        .tint(Palette.accent)
        .task { permissions.refresh() }
        .onReceive(accessibilityPoll) { _ in
            if step == .accessibility, permissions.accessibility != .granted { permissions.refresh() }
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            if isUpdate {
                page(symbol: "lock.shield",
                     title: "A few permissions to check",
                     body: "This version of Minutes can do more with \(permissionSteps.count == 1 ? "one permission" : "\(permissionSteps.count) permissions") it doesn't have yet. Each is explained before macOS asks, and every one is optional — skip any and it stays available in Settings › Permissions.")
            } else {
                page(symbol: "waveform",
                     title: "Welcome to Minutes",
                     body: "Meetings are recorded and transcribed on this Mac — nothing leaves it — and the notes are written with your own Claude subscription.\n\nA few permissions make that work. Each is explained before macOS asks.")
            }

        case .microphone:
            page(symbol: "microphone",
                 title: "Microphone",
                 body: "Your side of a call, and the whole room in an in-person meeting.\n\nWithout it, recordings only capture the other participants.",
                 status: microphoneStatus)

        case .systemAudio:
            page(symbol: "speaker.wave.2",
                 title: "System audio",
                 body: "Everyone else on the call — the audio your Mac plays. You keep hearing the meeting normally.\n\nmacOS asks the first time it's used, so this plays a short test sound and listens for it. If a prompt appears, allow it.",
                 status: systemAudioStatus)

        case .notifications:
            page(symbol: "bell.badge",
                 title: "Notifications",
                 body: "When you join a Zoom or Teams call, recording starts by itself and a banner says so — with Stop and Discard buttons. Browser calls like Meet ask first. You can switch to always asking in Settings.\n\nIf you decline notifications, a small floating notice near the menu bar does the same job.",
                 status: notificationStatus)

        case .accessibility:
            page(symbol: "macwindow",
                 title: "Accessibility",
                 body: "Lets Minutes read the title of a Teams or Webex call window, so a call that isn't on your calendar is named after the meeting instead of \"Microsoft Teams call, 10:02\". Only window titles are read.\n\nmacOS adds Minutes to the list; switch it on there and come back.",
                 status: accessibilityStatus)

        case .calendar:
            page(symbol: "calendar",
                 title: "Calendar",
                 body: "Names recordings after the meeting and brings in who was invited, lists today's meetings, and reminds you a minute before each one with Join & Record. Your calendar never leaves this Mac.",
                 status: calendarStatus)

        case .done:
            page(symbol: "checkmark.seal",
                 title: "That's it",
                 body: "Join a call and Minutes records it, or start any time from the menu bar icon or ⇧⌘R. Let people know you're recording — some places require everyone's consent.\n\nType notes while the meeting runs — they steer the summary. Everything here can be changed later in Settings.")
        }
    }

    private func page(symbol: String, title: String, body text: String,
                      status: (some View)? = EmptyView()) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.inkSecondary)
                .frame(height: 44)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            status
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Per-step status and actions

    @ViewBuilder
    private var microphoneStatus: some View {
        switch permissions.microphone {
        case .granted:
            grantedBadge("Microphone allowed")
        case .notDetermined:
            actionButton(permissions.isRequestingMicrophone ? "Waiting for macOS…" : "Allow Microphone",
                         disabled: permissions.isRequestingMicrophone) {
                Task { await permissions.requestMicrophone() }
            }
        case .denied:
            deniedRow("Denied. It can be enabled in System Settings — recordings work either way.") {
                permissions.openMicrophoneSettings()
            }
        }
    }

    @ViewBuilder
    private var systemAudioStatus: some View {
        switch permissions.systemAudio {
        case .working:
            grantedBadge("Heard the test sound — system audio works")
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Playing a test sound…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .untested:
            actionButton("Play a test sound") {
                Task { await permissions.checkSystemAudio() }
            }
        case .silent, .noAudio:
            deniedRow("Nothing was heard. If a permission prompt appeared, allow it, then test again — or enable Minutes under Audio Recording.") {
                permissions.openAudioCaptureSettings()
            }
            actionButton("Test again") {
                Task { await permissions.checkSystemAudio() }
            }
        case .failed(let reason):
            deniedRow(reason) { permissions.openAudioCaptureSettings() }
        }
    }

    @ViewBuilder
    private var notificationStatus: some View {
        switch permissions.notifications {
        case .granted:
            grantedBadge("Notifications enabled")
        case .notDetermined:
            actionButton(notificationsAnswered ? "Waiting for macOS…" : "Enable Notifications",
                         disabled: notificationsAnswered) {
                notificationsAnswered = true
                NotificationPresenter.request { _ in
                    Task { @MainActor in
                        notificationsAnswered = false
                        permissions.refresh()
                    }
                }
            }
        case .denied:
            deniedRow("Declined — the floating prompt will be used instead. Change it any time in System Settings.") {
                NotificationPresenter.openSystemSettings()
            }
        }
    }

    @ViewBuilder
    private var accessibilityStatus: some View {
        if permissions.accessibility == .granted {
            grantedBadge("Accessibility allowed")
        } else {
            actionButton("Open Accessibility Settings") {
                CallWindowTitle.requestAccess()
                permissions.openAccessibilitySettings()
            }
        }
    }

    @ViewBuilder
    private var calendarStatus: some View {
        if AppSettings.shared.calendarEnabled, permissions.calendar == .granted {
            grantedBadge("Calendar connected")
        } else if permissions.calendar == .denied {
            deniedRow("Calendar access was declined. It can be allowed in System Settings.") {
                permissions.openCalendarSettings()
            }
        } else {
            actionButton("Use My Calendar") {
                AppSettings.shared.calendarEnabled = true
                Task {
                    await CalendarService.shared.requestAccess()
                    permissions.refresh()
                    RecordingCoordinator.current?.calendarSettingChanged()
                }
            }
        }
    }

    // MARK: - Pieces

    private func actionButton(_ title: String, disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Palette.controlFill))
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
        
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func grantedBadge(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Palette.fill))
    }

    private func deniedRow(_ text: String, openSettings: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            IconButton(symbol: "gearshape", help: "Open System Settings", action: openSettings)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .done {
                Button("Skip for now") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Progress dots.
            HStack(spacing: 5) {
                ForEach(steps.indices, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? Palette.accent : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button(step == .done ? "Start using Minutes" : "Continue") {
                if index + 1 < steps.count {
                    index += 1
                } else {
                    finish()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.ink)
            .buttonBorderShape(.capsule)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
