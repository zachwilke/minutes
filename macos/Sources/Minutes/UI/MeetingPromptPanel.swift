import SwiftUI
import AppKit

/// A floating prompt that appears near the menu bar when a call is detected.
///
/// This exists because a banner is not guaranteed. Notification permission can be
/// denied — or, as on this machine, cached as denied — and in that state the app
/// would detect a meeting and then say nothing at all. A panel is not subject to
/// notification permission, so the feature works regardless.
///
/// It deliberately does not take focus: joining a call is a busy moment and
/// stealing keyboard focus mid-sentence would be hostile.
@MainActor
final class MeetingPromptPanel {
    static let shared = MeetingPromptPanel()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// How long the prompt lingers before withdrawing itself. Long enough to
    /// settle into a call and notice it, short enough not to become clutter.
    private let lifetime: Duration = .seconds(40)
    /// Fixed width; the height follows the content.
    fileprivate static let width: CGFloat = 328

    private init() {}

    /// Best available intrinsic height, clamped so a bad measurement can never
    /// produce a sliver or a panel that covers the screen.
    private static func height(of hosting: NSView) -> CGFloat {
        var measured = hosting.fittingSize.height
        if measured < 1 { measured = hosting.intrinsicContentSize.height }
        guard measured > 1 else { return 108 }
        return min(max(measured, 72), 220)
    }

    /// Asks whether to record a detected call.
    func show(appName: String,
              ambiguous: Bool,
              onRecord: @escaping () -> Void,
              onIgnore: @escaping () -> Void) {
        present(MeetingPromptView(
            symbol: "dot.radiowaves.left.and.right",
            title: "\(appName) call detected",
            message: ambiguous
                ? "\(appName) is using your microphone. This might be a meeting."
                : "Record it and write notes when it ends?",
            primary: .init(title: "Record", symbol: "record.circle.fill", tint: Palette.recording),
            secondaryTitle: "Not now",
            onPrimary: { [weak self] in self?.hide(); onRecord() },
            onSecondary: { [weak self] in self?.hide(); onIgnore() },
            onClose: { [weak self] in self?.hide(); onIgnore() }
        ), label: appName)
    }

    /// Says a recording started by itself, with the way out. Closing it keeps
    /// recording — only Stop and Discard change anything.
    func showAutoRecording(appName: String,
                           onStop: @escaping () -> Void,
                           onDiscard: @escaping () -> Void) {
        present(MeetingPromptView(
            symbol: "record.circle.fill",
            title: "Recording your \(appName) call",
            message: "Notes will be written when it ends.",
            primary: .init(title: "Stop", symbol: "stop.fill", tint: Palette.recording),
            secondaryTitle: "Discard",
            onPrimary: { [weak self] in self?.hide(); onStop() },
            onSecondary: { [weak self] in self?.hide(); onDiscard() },
            onClose: { [weak self] in self?.hide() }
        ), label: appName)
    }

    /// The one-minute calendar reminder, for when banners are blocked.
    func showReminder(_ event: CalendarService.Upcoming, onJoin: @escaping () -> Void) {
        present(MeetingPromptView(
            symbol: "calendar",
            title: event.title,
            message: event.meetingLink == nil ? "Starts in a minute." : "Starts in a minute. Join the call and record it?",
            primary: .init(title: event.meetingLink == nil ? "Record" : "Join & Record",
                           symbol: "record.circle.fill", tint: Palette.recording),
            secondaryTitle: "Dismiss",
            onPrimary: { [weak self] in self?.hide(); onJoin() },
            onSecondary: { [weak self] in self?.hide() },
            onClose: { [weak self] in self?.hide() }
        ), label: event.title)
    }

    private func present(_ content: MeetingPromptView, label appName: String) {
        hide()

        // Measure the content rather than guessing a height. The previous fixed
        // 118pt frame left a large empty band under the buttons, because the
        // content is shorter than that and was being stretched to fill it.
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: Self.height(of: hosting))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(contentRect: hosting.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar                 // above ordinary windows
        panel.backgroundColor = .clear            // the glass shape provides the fill
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        // Follow the user across spaces and sit alongside full-screen apps —
        // a call is very often joined from a full-screen window.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Re-fit now the view is in a window: SwiftUI layout before that point
        // can report nothing useful, and a panel sized from a zero measurement
        // would be a bare strip.
        panel.layoutIfNeeded()
        let settled = Self.height(of: hosting)
        if abs(settled - size.height) > 1 {
            panel.setContentSize(NSSize(width: Self.width, height: settled))
        }
        Log.info("Meeting prompt panel sized \(Int(Self.width))x\(Int(panel.frame.height))")

        position(panel)
        // orderFrontRegardless, not makeKeyAndOrderFront: showing the prompt must
        // not pull focus away from whatever is being typed.
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { [weak self, lifetime] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.hide()
        }

        Log.info("Showed meeting prompt panel for \(appName)")
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel != nil }

    /// Directly under the menu bar icon, so the prompt reads as coming from
    /// Minutes rather than appearing from nowhere.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        let anchor = Self.statusItemAnchor()
        guard let screen = anchor?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        var origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.frame.midX - size.width / 2,
                             y: anchor.frame.minY - size.height - 6)
        } else {
            // No status item yet (it does not exist during --test-prompt before
            // the scene is built): fall back to the top-right corner.
            origin = NSPoint(x: visible.maxX - size.width - 16,
                             y: visible.maxY - size.height - 12)
        }

        // Keep it wholly on screen. An icon near the right edge would otherwise
        // centre a panel that hangs off it.
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)

        Log.info("Positioned prompt at \(Int(origin.x)),\(Int(origin.y)) "
                 + (anchor == nil ? "(no menu bar anchor; used top-right)"
                                  : "(under the menu bar icon)"))
    }

    /// Records at launch whether the menu bar icon can be found, so prompt
    /// placement is diagnosable without waiting for a call — or clicking
    /// anything. `--test-prompt` runs in its own process and never has an
    /// anchor, so it cannot answer this question.
    func logAnchorState() {
        guard let anchor = Self.statusItemAnchor() else {
            Log.warn("Menu bar anchor not found — prompts will appear top-right")
            return
        }
        let display = Self.screenID(anchor.screen).map(String.init) ?? "unknown"
        Log.info("Menu bar anchor found at \(Int(anchor.frame.midX)),\(Int(anchor.frame.minY)) "
                 + "on display \(display) — prompts will appear beneath the icon")
    }

    /// Locates the menu bar icon.
    ///
    /// MenuBarExtra does not expose its NSStatusItem, but the item lives in a
    /// window of class NSStatusBarWindow. AppKit creates one of those per screen,
    /// so the one on the screen whose menu bar is currently active is the one to
    /// anchor to — otherwise the prompt can land on a different display entirely.
    private static func statusItemAnchor() -> (frame: NSRect, screen: NSScreen)? {
        let candidates = NSApplication.shared.windows.filter {
            String(describing: type(of: $0)) == "NSStatusBarWindow"
        }
        guard !candidates.isEmpty else { return nil }

        let activeID = screenID(NSScreen.main)
        let preferred = candidates.first { screenID($0.screen) == activeID } ?? candidates[0]
        guard let screen = preferred.screen ?? NSScreen.main else { return nil }
        return (preferred.frame, screen)
    }

    /// Screens must be compared by display ID; NSScreen instances are not stable
    /// enough to compare directly.
    private static func screenID(_ screen: NSScreen?) -> CGDirectDisplayID? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}

private struct MeetingPromptView: View {
    struct Primary {
        var title: String
        var symbol: String?
        var tint: Color
    }

    let symbol: String
    let title: String
    let message: String
    let primary: Primary
    let secondaryTitle: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                IconButton(symbol: "xmark", help: "Close", emphasis: .plain, size: 10, action: onClose)
            }

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                // These draw their own fills rather than using the standard
                // button styles. The panel is deliberately non-activating, and
                // macOS renders controls in a window that is not key using their
                // inactive appearance — which read as greyed-out and disabled.
                PromptButton(title: primary.title,
                             symbol: primary.symbol,
                             filled: true,
                             tint: primary.tint,
                             action: onPrimary)
                PromptButton(title: secondaryTitle,
                             symbol: nil,
                             filled: false,
                             tint: Palette.ink,
                             action: onSecondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: MeetingPromptPanel.width, alignment: .topLeading)
        .background(Palette.raised)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .tint(Palette.ink)
    }
}


/// A button that looks the same whether or not its window is key.
///
/// The standard styles derive their colours from window activation, so in a
/// non-activating panel they render as though disabled. These fills are explicit.
private struct PromptButton: View {
    let title: String
    let symbol: String?
    let filled: Bool
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(filled ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(filled
                               ? tint.opacity(isHovering ? 1.0 : 0.92)
                               : Color.primary.opacity(isHovering ? 0.14 : 0.08))
            }
            .overlay {
                Capsule().strokeBorder(filled ? Color.clear : Color.primary.opacity(0.18),
                                       lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
