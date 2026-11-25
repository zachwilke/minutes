import Foundation
import Testing
@testable import Minutes

/// A call on laptop speakers: the far side leaks into the mic at 0.8 of its
/// level (−2 dB), close to the median measured on a real Teams call.
struct EchoLabelTests {
    func speakerphoneTrack(userTalksFrom userStart: Float = 20, to userEnd: Float = 30) -> EnergyTrack {
        var track = EnergyTrack()
        for i in 0..<400 {
            let t = Float(i) / 10
            let userTalking = t >= userStart && t < userEnd
            let system: Float = userTalking ? 0.002 : 0.08 * (1 + 0.3 * sin(t))   // far side talks otherwise
            let mic: Float = (userTalking ? 0.12 : 0.004) + 0.8 * system           // leak at 0.8
            track.frames.append(.init(time: t, mic: mic, system: system))
        }
        return track
    }

    @Test func estimatesTheLeak() {
        let coupling = speakerphoneTrack().echoCoupling
        #expect(coupling > 0.7 && coupling < 0.9)
    }

    @Test func farSideThroughSpeakersIsThemNotSpeaker() {
        let track = speakerphoneTrack()
        // Without correction the leak sits on the threshold.
        #expect(track.speaker(from: 2, to: 8) != .others)
        let coupling = track.echoCoupling
        #expect(track.speaker(from: 2, to: 8, echoCoupling: coupling) == .others)
        #expect(track.speaker(from: 22, to: 28, echoCoupling: coupling) == .me)
    }

    @Test func headphonesNeedNoCorrection() {
        var track = EnergyTrack()
        for i in 0..<400 {
            let t = Float(i) / 10
            track.frames.append(.init(time: t, mic: 0.003, system: 0.08))
        }
        #expect(track.echoCoupling == 0)
    }
}
