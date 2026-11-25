import SwiftUI
import AppKit

/// AppKit's behind-window blur, which is what actually samples the desktop and
/// windows underneath. SwiftUI's materials only blur content within the window,
/// so they cannot produce this on their own.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // .active rather than .followsWindowActiveState: the blur should not
        // collapse to flat grey the moment you click another window.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
    }
}

/// Reaches the hosting NSWindow, which SwiftUI does not expose.
///
/// Two things happen here. Behind-window vibrancy only shows through if the
/// window stops painting an opaque background, which is an AppKit-level
/// property. And the titlebar is emptied: no title string, no separator, drag
/// anywhere. A notes app should look like a page with traffic lights on it,
/// not a document inside a frame, and the chrome is most of the difference.
struct WindowConfigurator: NSViewRepresentable {
    var translucent: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let translucent = self.translucent
        // The view has no window during the first layout pass.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !translucent
            window.backgroundColor = translucent ? .clear : NSColor(Palette.paper)
            // Always transparent, not only when translucent: an opaque titlebar
            // draws its own grey band across the top of the paper.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
    }
}

/// The window's ground: warm paper.
///
/// There is no gradient and no tint. The previous build washed the whole window
/// in brand green, which is exactly the sort of thing that looks like identity
/// in a screenshot and like interference behind three paragraphs of notes.
struct WindowBackground: View {
    let translucent: Bool

    var body: some View {
        BrandBackground(translucent: translucent)
            .ignoresSafeArea()
            .background(WindowConfigurator(translucent: translucent))
    }
}

/// The ground on its own, with no NSWindow configuration.
///
/// Use this anywhere the host window must not be reconfigured: the menu bar
/// popover (whose window is managed by MenuBarExtra) and the Settings swatches,
/// which would otherwise punch a hole in the Settings window.
struct BrandBackground: View {
    let translucent: Bool

    var body: some View {
        ZStack {
            if translucent {
                VisualEffectBackground(material: .underWindowBackground)
                // Enough paper to keep type legible over a busy desktop, little
                // enough that the blur is still visible.
                Palette.paper.opacity(0.72)
            } else {
                Palette.paper
            }
        }
    }
}
