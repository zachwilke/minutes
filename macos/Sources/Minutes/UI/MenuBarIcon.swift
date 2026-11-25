import AppKit

/// The menu bar item: the app icon's mark — waveform bars becoming lines of
/// text — at menu bar size, in the state the app is in.
///
/// A microphone said "this app uses audio", and looked the same whether or not
/// anything was being recorded; its filled and outlined forms are two pixels
/// apart at this size. This says what is happening:
///
/// - Idle: the mark, monochrome, like any other menu bar item.
/// - Recording: the tallest bar turns red and pulses once a second. Red is the
///   only colour in the menu bar most of the time, which is why it is reserved
///   for the one state you must never miss.
/// - Writing notes: the bars dim and the lines stay — the sound is done, the
///   words are still being written.
///
/// Images, not views. The status item's label must stay a plain image (or an
/// image and a title): anything that lays itself out sends it into an endless
/// update loop at launch. The pulse rides the once-a-second clock update the
/// label already receives, so it adds no timer of its own.
enum MenuBarIcon {
    enum State: Hashable {
        case idle
        case processing
        /// `lit` alternates each second while recording.
        case recording(lit: Bool)
    }

    static func image(_ state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = make(state)
        cache[state] = image
        return image
    }

    nonisolated(unsafe) private static var cache: [State: NSImage] = [:]

    /// The canvas macOS expects for a status item: 18 pt wide, a little less
    /// than the menu bar is tall.
    static let size = NSSize(width: 18, height: 16)

    private static func make(_ state: State) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(state)
            return true
        }
        // Template images are tinted by the system to suit the menu bar —
        // black on a light bar, white on a dark one. The recording state has
        // to carry red, so it is drawn in colour and does its own tinting
        // through the label colour, which resolves against the appearance it
        // is drawn into.
        if case .recording = state {
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        image.accessibilityDescription = switch state {
        case .idle: "Minutes"
        case .processing: "Minutes — writing notes"
        case .recording: "Minutes — recording"
        }
        return image
    }

    /// Geometry in points on the 18 × 16 canvas, y up. Edges sit on the half
    /// point, which is a whole pixel on every Retina display.
    private static func draw(_ state: State) {
        let ink: NSColor
        let accent: NSColor
        var accentAlpha: CGFloat = 1
        var barsAlpha: CGFloat = 1
        switch state {
        case .idle:
            ink = .black; accent = .black
        case .processing:
            ink = .black; accent = .black; barsAlpha = 0.35; accentAlpha = 0.35
        case .recording(let lit):
            ink = .labelColor; accent = .systemRed; accentAlpha = lit ? 1 : 0.5
        }

        let weight: CGFloat = 2
        func capsule(_ rect: NSRect, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: weight / 2, yRadius: weight / 2).fill()
        }
        func bar(centerX: CGFloat, height: CGFloat, _ color: NSColor) {
            capsule(NSRect(x: centerX - weight / 2, y: 8 - height / 2, width: weight, height: height), color)
        }
        func line(from x0: CGFloat, to x1: CGFloat, centerY: CGFloat, _ color: NSColor) {
            capsule(NSRect(x: x0, y: centerY - weight / 2, width: x1 - x0, height: weight), color)
        }

        // Sound: short, tall, short — the tall one is the one that turns red.
        bar(centerX: 2, height: 6, ink.withAlphaComponent(barsAlpha))
        bar(centerX: 5.5, height: 12, accent.withAlphaComponent(accentAlpha))
        bar(centerX: 9, height: 4, ink.withAlphaComponent(barsAlpha))
        // Words: two lines, the second shorter.
        // Every stroke sets its alpha the same way, so bars and lines come out
        // the same weight of ink; mixing the label colour's own transparency
        // with explicit alphas made the bars blacker than the lines.
        line(from: 11.5, to: 17.5, centerY: 10.5, ink.withAlphaComponent(1))
        line(from: 11.5, to: 15.5, centerY: 5.5, ink.withAlphaComponent(0.75))
    }
}
