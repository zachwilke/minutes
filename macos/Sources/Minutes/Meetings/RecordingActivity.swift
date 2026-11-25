import Foundation
import Combine

/// The fast-changing state of a live recording: the elapsed clock (1 Hz), input
/// levels (~10 Hz) and the streaming live transcript.
///
/// Split off RecordingCoordinator deliberately. SwiftUI re-evaluates the body of
/// every view observing an ObservableObject when *any* of its @Published values
/// change, and several views observe the coordinator, including the whole
/// detail pane. With the level meters publishing there, every audio tick
/// re-rendered the window, ten times a second, for the length of a recording.
///
/// The same reasoning splits this object three ways. With levels and the live
/// text published here too, everything that only shows the *clock* — the menu
/// bar item, the toolbar's Stop button — redrew at the meter rate, and the
/// live transcript re-laid out its whole text on every level tick. So the clock
/// stays here, and the two faster streams have objects of their own that only
/// the views drawing them subscribe to. The forwarding properties keep the
/// writers unchanged.
@MainActor
final class RecordingActivity: ObservableObject {
    @Published var elapsed: TimeInterval = 0

    /// Observed only by level meters.
    let meters = Meters()
    /// Observed only by the live transcript.
    let live = LiveText()

    var levels: AudioCaptureEngine.Levels {
        get { meters.levels }
        set { meters.levels = newValue }
    }

    var liveText: String {
        get { live.text }
        set { if live.text != newValue { live.text = newValue } }
    }

    func reset() {
        meters.levels = AudioCaptureEngine.Levels()
        elapsed = 0
        live.text = ""
    }

    @MainActor
    final class Meters: ObservableObject {
        @Published var levels = AudioCaptureEngine.Levels()
    }

    @MainActor
    final class LiveText: ObservableObject {
        @Published var text = ""
    }
}
