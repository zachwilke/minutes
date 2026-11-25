import SwiftUI
import AppKit

/// The app's colour and shape language: warm paper, dark ink, and almost
/// nothing else.
///
/// Minutes is a notes app. The thing on screen that should hold your attention
/// is a page of text, and every saturated surface behind it competes for that
/// attention. So the palette is near-monochrome: a warm off-white ground, a
/// slightly brighter surface for the page itself, ink and two greys for type,
/// and one hairline. Colour is spent only where it carries information that
/// shape and weight cannot — recording red, and the states a warning or failure
/// needs to be seen in.
///
/// The warmth matters. A neutral grey interface reads as cold and
/// machine-made; shifting the whole ramp a few degrees toward yellow makes the
/// same layout read as paper. Every value here is appearance-aware, because a
/// single fixed tone would either glare in light mode or go muddy in dark.
enum Palette {

    // MARK: - Ground and surfaces

    /// The window's ground. Everything sits on this.
    static let paper = dynamic(light: 0xF4F2EE, dark: 0x191918)
    /// The page: notes, the sidebar's selected row, any card.
    static let surface = dynamic(light: 0xFCFBF9, dark: 0x222120)
    /// A surface that must sit *above* another one — a popover over a page.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x2B2A28)

    // MARK: - Type

    /// Body text and anything primary.
    static let ink = Color(nsColor: NS.ink)
    /// Secondary text: metadata lines, captions, inactive labels.
    static let inkSecondary = Color(nsColor: NS.inkSecondary)
    /// Tertiary: timestamps, placeholders, things you read only on purpose.
    static let inkTertiary = Color(nsColor: NS.inkTertiary)

    // MARK: - Lines and fills

    /// The one separator weight in the app. Drawn at 0.5pt.
    static let hairline = Color(nsColor: NS.hairline)
    /// Hover and inactive control fills.
    static let fill = Color(nsColor: NS.fill)
    /// The selected row in a list.
    static let selection = dynamic(light: 0xE2DDD3, dark: 0x3A3733)

    // MARK: - The little colour there is

    /// Recording, live indicators, the one control that must never be missed.
    static let recording = dynamic(light: 0xD8382F, dark: 0xFF5F55)
    static let warning = dynamic(light: 0x976312, dark: 0xE0A54C)
    static let danger = dynamic(light: 0xB03229, dark: 0xFF6B60)

    /// The far side of a conversation, in the transcript.
    ///
    /// Two speakers have to be told apart at a glance, and weight alone does not
    /// do it down a long column. This is as close to neutral as a second colour
    /// can get and still separate: a cool slate that reads as grey until it sits
    /// beside ink, where the temperature difference does the work.
    static let speakerOther = dynamic(light: 0x5A6472, dark: 0x9BA6B5)

    // MARK: - Compatibility aliases
    //
    // The green identity is gone from the interface, but these names are used
    // across Settings, onboarding and the menu bar. They map onto the neutral
    // ramp so every one of those call sites renders in the new language without
    // a parallel vocabulary to keep straight.

    /// Was the brand green. Now ink, which is what a fill is made of here.
    static let brand = ink
    static let brandSoft = inkSecondary
    /// Interactive and textual emphasis.
    static let accent = ink
    /// Quieter labels: section headers, muted icons.
    static let accentMuted = inkSecondary

    /// Kept so glass call sites compile; there is no tint any more.
    static func glassTint(_ intensity: Double = 1) -> Color { .clear }

    /// Flat ink. A gradient would be the only one in the app.
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [ink, ink], startPoint: .top, endPoint: .bottom)
    }

    /// Fill for a primary control: a solid ink pill with white type. Granola's
    /// one loud control, and the reason nothing else has to shout.
    static var controlFill: LinearGradient {
        LinearGradient(colors: [ink, ink], startPoint: .top, endPoint: .bottom)
    }

    static var recordFill: LinearGradient {
        LinearGradient(colors: [recording, recording], startPoint: .top, endPoint: .bottom)
    }

    /// Level-meter fill. Ink, not green: the meter says *how loud*, and the
    /// colour was never carrying that.
    static var meterGradient: LinearGradient {
        LinearGradient(colors: [inkSecondary, ink], startPoint: .leading, endPoint: .trailing)
    }

    /// The tokens AppKit views need, as NSColor — the notes text view draws
    /// with these. The SwiftUI colours above are built from them, so the two
    /// can never drift apart.
    enum NS {
        static let ink = dynamic(light: 0x1C1B19, dark: 0xECE9E3)
        static let inkSecondary = dynamic(light: 0x6B6660, dark: 0x9E9890)
        static let inkTertiary = dynamic(light: 0x9C958B, dark: 0x6E6963)
        static let hairline = dynamic(light: 0xE3DFD7, dark: 0x343230)
        static let fill = dynamic(light: 0xEAE6DF, dark: 0x2E2C2A)

        static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return Palette.nsColor(isDark ? dark : light)
            }
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NS.dynamic(light: light, dark: dark))
    }

    fileprivate static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

/// The type scale.
///
/// A notes app is mostly one long column of text, so the document sizes are set
/// once here rather than guessed per view. Body is 15pt, not the 13 a macOS
/// control would use: this is prose to read, not a label to scan.
enum Typeface {
    /// Page headings — "Coming up", a meeting's title. A serif, because a
    /// heading set in the same face as the controls around it reads as one
    /// more control; New York reads as the top of a page.
    static func display(_ size: CGFloat = 31) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
    static let documentTitle = Font.system(size: 30, weight: .medium, design: .serif)
    static let documentBody = Font.system(size: 15)
    static let documentLineSpacing: CGFloat = 6

    static let sectionHeading = Font.system(size: 17, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    /// A meeting in the Home list. Larger than a sidebar row: it is the
    /// thing on the page, not navigation beside it.
    static let listTitle = Font.system(size: 15, weight: .regular)
    static let listSubtitle = Font.system(size: 12.5)
    static let label = Font.system(size: 12)
    static let meta = Font.system(size: 11)
    /// Group headers and other small caps-ish labels.
    static let eyebrow = Font.system(size: 10, weight: .semibold)
}

/// Dates and times, in the user's own conventions.
///
/// The previous build hard-coded "HH:mm" and "EEEE d MMMM", which put a
/// 24-hour clock and day-month order in front of everyone regardless of
/// locale. These go through FormatStyle, which follows System Settings and
/// caches its formatters, so calling them from a row body is cheap.
enum Formats {
    /// "3:28 PM", or "15:28" where that is the convention.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "9:30 – 10:00 AM".
    static func timeRange(_ start: Date, _ end: Date) -> String {
        (start..<max(end, start)).formatted(.interval.hour().minute())
    }

    /// "Today", "Yesterday", "Tue, Nov 17", or "Tue, Nov 17, 2024" outside
    /// this year.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        return calendar.isDate(date, equalTo: Date(), toGranularity: .year)
            ? date.formatted(style)
            : date.formatted(style.year())
    }

    /// "Fri, Nov 13 · 1:51 PM", for a meeting's header.
    static func dayAndTime(_ date: Date) -> String {
        "\(day(date)) · \(time(date))"
    }
}

/// Corner radii, as a scale rather than magic numbers.
///
/// Tighter than the previous Liquid Glass set. Heavy curvature reads as
/// software; paper has corners you barely notice.
enum Radius {
    static let chip: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 10
    static let pane: CGFloat = 12
    static let window: CGFloat = 20
}

/// Window-level spacing.
enum Layout {
    /// Distance from the window's edge to any content.
    static let windowInset: CGFloat = 24
    /// Gap between panes.
    static let paneGap: CGFloat = 12
    /// Padding inside a card.
    static let cardPadding: CGFloat = 18
    /// Breathing room above a header.
    static let headerTop: CGFloat = 14
    /// Distance from the sidebar's edges to its content.
    static let sidebarInset: CGFloat = 10

    /// How wide the reading column is allowed to get.
    ///
    /// Notes are read, not scanned, and a line of prose stops being readable
    /// somewhere past 90 characters. On a wide display the column stays here and
    /// the paper takes the rest, which is what makes a maximised window still
    /// look like a page.
    static let documentWidth: CGFloat = 700
    /// The Home list and its calendar card: a little wider than prose, since
    /// rows carry a time at their far edge.
    static let homeWidth: CGFloat = 760
    /// Gutter either side of the document column.
    static let documentGutter: CGFloat = 40
    /// Width of the transcript / Ask panel.
    static let panelWidth: CGFloat = 380
}

extension View {
    /// A hairline rule. The app's only separator.
    func hairline(_ edge: Edge) -> some View {
        overlay(alignment: edge == .top ? .top
                         : edge == .bottom ? .bottom
                         : edge == .leading ? .leading : .trailing) {
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: edge == .leading || edge == .trailing ? 0.5 : nil,
                       height: edge == .top || edge == .bottom ? 0.5 : nil)
        }
    }

    /// A floating surface: banners, popovers, the recording pill.
    ///
    /// Opaque, not glass. A blurred desktop behind a line of text is a
    /// legibility cost paid for an effect, and this app's text is the product.
    func floatingCard(radius: CGFloat = Radius.card) -> some View {
        // The shadow belongs to the card's shape, not to the composed view. On
        // the whole view it is recomputed from the content's alpha every time
        // the content changes — ten times a second for a recording pill full of
        // level meters. On the shape alone it is drawn once.
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Palette.raised)
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5)
        }
    }

    /// Kept for call sites that asked for glass; now the flat card above.
    func glassCard(radius: CGFloat = Radius.card, tinted: Bool = true) -> some View {
        floatingCard(radius: radius)
    }

    /// Chrome for a small control.
    ///
    /// `filled` is the one primary action in a view: solid ink, white glyph.
    /// Everything else is a quiet fill that only appears under the pointer.
    @ViewBuilder
    func glassCapsule(gradient: LinearGradient? = nil, tint: Color, filled: Bool) -> some View {
        if filled {
            background(Capsule().fill(gradient ?? Palette.controlFill))
        } else {
            background(Capsule().fill(Palette.fill))
        }
    }

    /// A content pane: the page itself.
    /// `enabled: false` leaves the view bare, for content already inside a pane.
    @ViewBuilder
    func contentPane(radius: CGFloat = Radius.pane, translucent: Bool, enabled: Bool = true) -> some View {
        if enabled {
            background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self
        }
    }
}

/// A row-height button that fills on hover — the sidebar row, the menu item,
/// anything in a list. Hover is the whole affordance, so it has to be reliable.
struct HoverFill: ViewModifier {
    var radius: CGFloat = Radius.control
    var isSelected = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(isSelected ? Palette.selection
                          : (isHovering ? Palette.fill : Color.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverFill(radius: CGFloat = Radius.control, isSelected: Bool = false) -> some View {
        modifier(HoverFill(radius: radius, isSelected: isSelected))
    }
}
