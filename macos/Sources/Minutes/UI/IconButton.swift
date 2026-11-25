import SwiftUI

/// An icon-only button.
///
/// Every instance requires `help`, which becomes the tooltip. That is not
/// decoration: stripping the label off a button removes its only affordance, and
/// the tooltip is what puts the meaning back. Nothing here should be an icon
/// whose meaning a tooltip cannot recover — destructive confirmations and dialog
/// dismissals keep their words.
///
/// Chrome is drawn only on hover. A toolbar of permanently outlined pills reads
/// as six competing controls; the same toolbar with nothing but glyphs reads as
/// a quiet row that lights up where the pointer is.
struct IconButton: View {
    enum Emphasis {
        /// Chromeless — for toolbars and dense rows.
        case plain
        /// Default: a visible control, for secondary actions.
        case bordered
        /// Filled — for the one primary action in a view.
        case prominent
    }

    let symbol: String
    let help: String
    var emphasis: Emphasis = .bordered
    var tint: Color?
    var size: CGFloat = 12

    let action: () -> Void

    /// Custom-drawn chrome does not pick up the system's disabled dimming the
    /// way a stock button style would, so without this a disabled control looked
    /// fully live and simply ignored clicks.
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    /// Square-ish rather than the old 3:2 pill. These sit in rows of four or
    /// five now, and a run of wide lozenges is most of what made the old
    /// toolbar feel heavy.
    private var side: CGFloat { max(26, size * 2) }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: side, height: side)
                .background {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(background)
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.3)
        .onHover { isHovering = $0 && isEnabled }
        .help(help)
        // The tooltip is the button's name: without this VoiceOver reads the
        // SF Symbol's own name — "sparkles", "ellipsis" — not the action.
        .accessibilityLabel(Text(help))
    }

    private var foreground: Color {
        switch emphasis {
        case .prominent: return Palette.surface
        case .bordered, .plain: return tint ?? (isHovering ? Palette.ink : Palette.inkSecondary)
        }
    }

    private var background: Color {
        switch emphasis {
        case .prominent: return tint ?? Palette.ink
        case .bordered: return isHovering ? Palette.selection : Palette.fill
        case .plain: return isHovering ? Palette.fill : .clear
        }
    }
}

/// The record / stop control.
///
/// Drawn rather than assembled from a symbol. `record.circle.fill` is itself a
/// ring around a dot, so putting it inside a circular button produced three
/// concentric circles — a donut. This is the familiar arrangement instead: a
/// solid red disc to start, a white square inside it to stop.
///
/// Red is the only saturated colour left in the interface, and it is here
/// because this is the one control whose state you must be able to read from
/// across the room.
struct RecordButton: View {
    let isRecording: Bool
    let isBusy: Bool
    var size: CGFloat = 13
    let start: () -> Void
    let stop: () -> Void

    @State private var isHovering = false

    private var side: CGFloat { max(26, size * 2) }

    var body: some View {
        Button(action: isRecording ? stop : start) {
            ZStack {
                Circle()
                    .fill(Palette.recording.opacity(isHovering ? 1 : 0.92))

                if isRecording {
                    // A rounded square, the universal stop mark.
                    RoundedRectangle(cornerRadius: side * 0.10, style: .continuous)
                        .fill(.white)
                        .frame(width: side * 0.32, height: side * 0.32)
                } else {
                    // An idle disc needs a mark, or it reads as a coloured dot
                    // rather than a record button.
                    Circle().fill(.white.opacity(0.92)).frame(width: side * 0.28, height: side * 0.28)
                }
            }
            .frame(width: side, height: side)
            .scaleEffect(isHovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy && !isRecording)
        .opacity(isBusy && !isRecording ? 0.45 : 1)
        .onHover { isHovering = $0 }
        .help(isRecording ? "Stop recording and write notes"
                          : (isBusy ? "Busy — finishing the last meeting" : "Start recording"))
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

/// A text button with a word on it, for the few places an icon would be a
/// guess. Ink-filled when it is the primary action, otherwise a quiet fill.
struct PillButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(prominent ? Palette.surface : Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(prominent
                               ? Palette.ink.opacity(isHovering ? 0.85 : 1)
                               : (isHovering ? Palette.selection : Palette.fill))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { isHovering = $0 && isEnabled }
    }
}
