import Foundation

/// Per-chunk loudness of each source. Because we know how loud the microphone
/// was versus how loud the system output was at any moment, we can label each
/// transcript segment "You" or "Them" without running a diarization model.
struct EnergyTrack: Sendable {
    struct Frame: Sendable {
        var time: Float      // seconds from start of recording
        var mic: Float       // RMS 0...1
        var system: Float    // RMS 0...1
    }

    var frames: [Frame] = []

    /// Decides who was talking across a time range. Requires a clear margin
    /// between the two sources, otherwise reports `.unknown` rather than
    /// inventing an attribution.
    /// How strongly the call's audio leaks into the microphone — speakers
    /// rather than headphones, recorded without echo cancellation. Estimated as
    /// the lower quartile of mic/system level wherever the call is clearly
    /// audible: in the quietest quarter of those moments the user is not
    /// talking, so what the mic hears is the leak alone. Below 0.1 (−20 dB) the
    /// leak is too small to matter and is ignored.
    ///
    /// Measured on a real Teams call over laptop speakers: 0.49, which left 38%
    /// of the meeting unattributable; subtracting it took that to 6%.
    var echoCoupling: Float {
        let ratios = frames.lazy.filter { $0.system > 0.01 }.map { $0.mic / $0.system }.sorted()
        guard ratios.count >= 50 else { return 0 }
        let quartile = min(ratios[ratios.count / 4], 1.5)
        return quartile < 0.1 ? 0 : quartile
    }

    /// `echoCoupling` (see above) is removed from the mic before comparing, so
    /// the far side heard through the speakers does not count as the user.
    /// Compute it once per recording and pass it to every call.
    func speaker(from start: TimeInterval, to end: TimeInterval, echoCoupling: Float = 0) -> Speaker {
        // Frames are appended in time order, so the window is found by binary
        // search instead of filtering the whole array. This runs once per
        // transcript segment; a two-hour meeting is ~72k frames, and the filter
        // made labelling O(frames × segments).
        let lower = Float(start - 0.15)
        let upper = Float(end + 0.15)
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].time < lower { lo = mid + 1 } else { hi = mid }
        }
        var micEnergy: Float = 0
        var systemEnergy: Float = 0
        var index = lo
        var any = false
        while index < frames.count, frames[index].time <= upper {
            let frame = frames[index]
            let mic = max(0, frame.mic - echoCoupling * frame.system)
            micEnergy += mic * mic
            systemEnergy += frame.system * frame.system
            any = true
            index += 1
        }
        guard any else { return .unknown }
        let total = micEnergy + systemEnergy
        guard total > 1e-7 else { return .unknown }

        let micShare = micEnergy / total
        if micShare > 0.62 { return .me }
        if micShare < 0.38 { return .others }
        return .unknown
    }

    // Stored as flat little-endian Float32 triples — compact and trivial to reread.
    func write(to url: URL) {
        var data = Data()
        data.reserveCapacity(frames.count * 12)
        for frame in frames {
            for value in [frame.time, frame.mic, frame.system] {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        try? data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> EnergyTrack {
        guard let data = try? Data(contentsOf: url), data.count >= 12 else { return EnergyTrack() }
        var track = EnergyTrack()
        let count = data.count / 12
        track.frames.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let base = index * 12
                func value(_ offset: Int) -> Float {
                    Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + offset,
                                                                             as: UInt32.self)))
                }
                track.frames.append(Frame(time: value(0), mic: value(4), system: value(8)))
            }
        }
        return track
    }
}
