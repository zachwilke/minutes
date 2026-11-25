import AppKit

/// Controls whether the app appears in the Dock, or lives only in the menu bar.
///
/// This is switched at runtime rather than through `LSUIElement` in Info.plist,
/// and the ordering matters. An `LSUIElement` app never builds a main menu, and
/// the standard editing shortcuts — ⌘C, ⌘V, ⌘Z in the notes editor — are key
/// equivalents on that menu. Launching as a regular app and *then* dropping to
/// accessory keeps the menu installed, so text editing keeps working even with no
/// Dock icon and no visible menu bar.
///
/// The cost is a brief Dock icon at launch before the policy is applied. That is
/// a better trade than losing paste in a note-taking app.
@MainActor
enum DockPresence {
    static func apply(showInDock: Bool) {
        let desired: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }

        guard NSApp.setActivationPolicy(desired) else {
            Log.warn("Could not switch activation policy to \(showInDock ? "regular" : "accessory")")
            return
        }
        Log.info("Dock presence: \(showInDock ? "shown in Dock" : "menu bar only")")

        if showInDock {
            // Returning from accessory leaves the app not frontmost, so its
            // windows can sit behind whatever else is open.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
