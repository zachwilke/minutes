import Foundation
import AVFoundation
import AppKit
import EventKit
import UserNotifications
import Combine

/// Surfaces the two permissions this app actually needs, so they can be granted
/// from Settings rather than by starting a recording and hoping.
///
/// The microphone is straightforward: AVFoundation reports its status and can
/// raise the prompt directly. System audio is not — a Core Audio process tap is
/// gated by the Audio Recording permission, and macOS exposes no API to query it
/// or request it. When it is missing the tap still runs and still reports
/// success; it just returns pure silence, which looks exactly like a recording of
/// a quiet room. The only reliable check is to capture a known sound and see
/// whether anything comes back, which is what `checkSystemAudio()` does.
@MainActor
final class PermissionsService: ObservableObject {
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined

        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not requested"
            }
        }
    }

    enum SystemAudioResult: Equatable {
        case untested
        case testing
        case working(peak: Float)
        case silent
        case noAudio
        case failed(String)
    }

    @Published private(set) var microphone: Status = .notDetermined
    @Published private(set) var calendar: Status = .notDetermined
    @Published private(set) var notifications: Status = .notDetermined
    /// Accessibility, for reading a call's name from its window. There is no
    /// "not determined": macOS only reports trusted or not.
    @Published private(set) var accessibility: Status = .notDetermined
    @Published private(set) var systemAudio: SystemAudioResult = .untested
    @Published private(set) var isRequestingMicrophone = false
    /// Extra guidance shown after a reset attempt, when the running process is
    /// still holding the old decision.
    @Published private(set) var resetHint: String?

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Permissions are usually changed in System Settings, in another app.
        // Re-reading them when we come back to the front keeps the UI honest.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        microphone = Self.status(from: AVCaptureDevice.authorizationStatus(for: .audio))
        calendar = Self.calendarStatus()
        accessibility = CallWindowTitle.isTrusted ? .granted : .notDetermined
        refreshNotifications()
    }

    /// Notification state is only available asynchronously.
    private func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status: Status
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .granted
            case .notDetermined: status = .notDetermined
            default: status = .denied
            }
            Task { @MainActor in self?.notifications = status }
        }
    }

    // MARK: - Microphone

    /// Raises the system prompt. Only possible while the status is
    /// `notDetermined`; once denied, the user has to change it in System
    /// Settings, so callers should offer that instead.
    func requestMicrophone() async {
        guard microphone == .notDetermined else {
            openMicrophoneSettings()
            return
        }
        isRequestingMicrophone = true
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        isRequestingMicrophone = false
        refresh()
        Log.info("Microphone access \(granted ? "granted" : "refused")")
    }

    /// Clears the decision macOS has recorded for this app so the prompt can be
    /// raised again.
    ///
    /// This matters here because the app is ad-hoc signed: its code identity
    /// changes on every rebuild, and a decision recorded against an older build —
    /// including an automatic denial from a build that asked before it had the
    /// audio-input entitlement — leaves the app stuck as Denied and absent from
    /// the System Settings list, with nothing there to switch on.
    func resetMicrophoneDecision() async {
        resetHint = nil
        let tccutil = URL(fileURLWithPath: "/usr/bin/tccutil")
        guard FileManager.default.isExecutableFile(atPath: tccutil.path) else {
            resetHint = "tccutil is not available on this system."
            return
        }

        do {
            let output = try await Shell.run(executable: tccutil,
                                            arguments: ["reset", "Microphone", AppPaths.bundleID])
            Log.info("tccutil reset exited \(output.status)")
        } catch {
            resetHint = "Could not reset the permission: \(error.localizedDescription)"
            return
        }

        refresh()
        if microphone == .notDetermined {
            await requestMicrophone()
            if microphone == .notDetermined {
                // The prompt is suppressed while the process still holds the old
                // decision in memory.
                resetHint = "Quit and reopen Minutes, then choose Request access."
            }
        } else {
            resetHint = "Quit and reopen Minutes, then choose Request access."
        }
    }

    // MARK: - System audio

    /// Records for a moment while playing a known sound through the speakers, and
    /// reports whether the tap actually heard it.
    ///
    /// This doubles as the trigger for the permission prompt: macOS asks the
    /// first time an app genuinely tries to tap system audio.
    func checkSystemAudio() async {
        systemAudio = .testing

        let engine = AudioCaptureEngine()
        let scratch = AppPaths.supportRoot.appendingPathComponent("permission-check.wav")

        do {
            // Opening the tap blocks, so keep it off the main actor.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try engine.start(writingTo: scratch, captureMic: false, captureSystem: true)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            systemAudio = .failed(error.localizedDescription)
            return
        }

        // Our own output is not excluded from the tap, so playing a sound here is
        // a self-contained test — no need for the user to start a video.
        if let sound = NSSound(named: "Submarine") {
            sound.play()
        }
        try? await Task.sleep(for: .seconds(2.5))

        let result = engine.stop()
        try? FileManager.default.removeItem(at: scratch)

        if !result.capturedSystem {
            systemAudio = .failed(result.degradedReason ?? "The system audio tap could not be opened.")
        } else if result.systemBuffersReceived == 0 {
            systemAudio = .noAudio
        } else if result.peakSystemLevel <= 0.0001 {
            systemAudio = .silent
        } else {
            systemAudio = .working(peak: result.peakSystemLevel)
        }
        Log.info("System audio check: \(systemAudio) (peak \(result.peakSystemLevel), buffers \(result.systemBuffersReceived))")
    }

    // MARK: - System Settings deep links

    /// Anchor names verified against SecurityPrivacyExtension on macOS 27.
    func openMicrophoneSettings() { Self.openPrivacyPane("Privacy_Microphone") }
    func openAudioCaptureSettings() { Self.openPrivacyPane("Privacy_AudioCapture") }
    func openCalendarSettings() { Self.openPrivacyPane("Privacy_Calendars") }
    func openAccessibilitySettings() { Self.openPrivacyPane("Privacy_Accessibility") }

    private static func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers

    /// Pure mapping — nonisolated so the command line diagnostics can reuse it.
    nonisolated static func status(from status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied      // .denied and .restricted both need System Settings
        }
    }

    nonisolated static func calendarStatus() -> Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
