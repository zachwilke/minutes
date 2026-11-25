import Foundation

/// Streaming 16-bit PCM WAV writer. Whisper wants 16 kHz mono, and writing that
/// directly keeps a 60-minute meeting under 120 MB with no post-processing step.
final class WAVWriter {
    static let sampleRate = 16_000
    private let handle: FileHandle
    private var framesWritten: Int = 0
    /// Set on the first failed write — a full disk, almost always. Read by the
    /// engine so the recording can say so instead of carrying on silently.
    private(set) var hasFailed = false
    private var framesAtLastHeaderRefresh = 0
    private let channels = 1
    private let bitsPerSample = 16
    /// How often the RIFF sizes are rewritten mid-recording. A WAV whose header
    /// still says zero length is unreadable, so if the app is force-quit or
    /// crashes we want the file on disk to already be valid. Refreshing every
    /// few seconds costs one seek and 44 bytes.
    private static let headerRefreshInterval = sampleRate * 5

    init(url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        fm.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(frames: 0, channels: channels,
                                                 sampleRate: Self.sampleRate,
                                                 bitsPerSample: bitsPerSample))
    }

    /// Appends float samples in [-1, 1], converting to little-endian Int16.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * 32_767.0)
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        do {
            try handle.write(contentsOf: Data(bytes))
            framesWritten += samples.count
            if framesWritten - framesAtLastHeaderRefresh >= Self.headerRefreshInterval {
                refreshHeader()
            }
        } catch {
            // Once, not once per chunk: a full disk fails every write after the
            // first, ten a second, and the log lives on the same full disk.
            if !hasFailed { Log.error("WAV append failed, later writes will be dropped: \(error)") }
            hasFailed = true
        }
    }

    /// Rewrites the sizes, then returns to the end to keep appending.
    private func refreshHeader() {
        do {
            let position = try handle.offset()
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(frames: framesWritten, channels: channels,
                                                     sampleRate: Self.sampleRate,
                                                     bitsPerSample: bitsPerSample))
            try handle.seek(toOffset: position)
            framesAtLastHeaderRefresh = framesWritten
        } catch {
            Log.warn("WAV header refresh failed: \(error)")
        }
    }

    var duration: TimeInterval { Double(framesWritten) / Double(Self.sampleRate) }

    /// Rewrites the RIFF/data sizes now that the final length is known.
    func close() {
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(frames: framesWritten, channels: channels,
                                                     sampleRate: Self.sampleRate,
                                                     bitsPerSample: bitsPerSample))
            try handle.close()
        } catch {
            Log.error("WAV close failed: \(error)")
        }
    }

    /// Repairs a file abandoned mid-recording, where the header still claims a
    /// length of zero, by deriving the real frame count from the file size.
    /// Returns the recovered duration, or nil if there is nothing to recover.
    @discardableResult
    static func repairHeaderIfNeeded(at url: URL) -> TimeInterval? {
        let headerBytes = 44
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > headerBytes
        else { return nil }

        let blockAlign = 1 * 16 / 8
        let frames = (size - headerBytes) / blockAlign
        guard frames > 0 else { return nil }

        // Only rewrite if the stored size is actually wrong.
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let stored = try? handle.read(upToCount: headerBytes), stored.count == headerBytes {
                let declared = stored.withUnsafeBytes {
                    UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self))
                }
                if Int(declared) == frames * blockAlign { return Double(frames) / Double(sampleRate) }
            }
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(frames: frames, channels: 1,
                                                sampleRate: sampleRate, bitsPerSample: 16))
        } catch {
            Log.error("WAV repair failed: \(error)")
            return nil
        }
        let duration = Double(frames) / Double(sampleRate)
        Log.info("Repaired WAV header at \(url.lastPathComponent): \(String(format: "%.1f", duration))s recovered")
        return duration
    }

    private static func header(frames: Int, channels: Int, sampleRate: Int, bitsPerSample: Int) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = frames * blockAlign
        var data = Data()
        func str(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { data.append(contentsOf: $0) } }

        str("RIFF");  u32(36 + dataBytes);  str("WAVE")
        str("fmt ");  u32(16)
        u16(1)                              // PCM
        u16(channels)
        u32(sampleRate)
        u32(sampleRate * blockAlign)        // byte rate
        u16(blockAlign)
        u16(bitsPerSample)
        str("data");  u32(dataBytes)
        return data
    }
}
