import Foundation

enum WhisperError: LocalizedError {
    case binaryMissing
    case modelMissing
    case noTranscription

    var errorDescription: String? {
        switch self {
        case .binaryMissing:
            return "whisper-cli was not found. Install it with: brew install whisper-cpp"
        case .modelMissing:
            return "No Whisper model was found in \(AppPaths.modelsRoot.path). Run Scripts/fetch-model.sh to download one."
        case .noTranscription:
            return "Whisper produced no transcript for this recording."
        }
    }
}

/// Runs the recorded audio through whisper.cpp for the authoritative transcript,
/// then labels each segment using the recorded mic-vs-system energy.
struct WhisperRefiner {
    /// 0...1, reported while Whisper works.
    var onProgress: (@Sendable (Double) -> Void)?

    func transcribe(audioFile: URL, energy: EnergyTrack) async throws -> [TranscriptSegment] {
        guard let binary = ToolLocator.find("whisper-cli") else { throw WhisperError.binaryMissing }
        guard let model = Self.preferredModel() else { throw WhisperError.modelMissing }

        let outputBase = audioFile.deletingPathExtension().appendingPathExtension("whisper")
        let jsonFile = outputBase.appendingPathExtension("json")
        try? FileManager.default.removeItem(at: jsonFile)

        // Four threads, at utility priority. Measured on a 19.7-minute meeting:
        // 8 threads at default priority and 4 at utility both took 43.5 s and
        // produced identical text — Metal does the heavy lifting, so the CPU
        // threads mostly wait. What the extra threads and the higher priority
        // did buy was contention with whatever else is running, which is often
        // the next call. On an 8-core M1 that call matters more than this does.
        let threads = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        let arguments = [
            "-m", model.path,
            "-f", audioFile.path,
            "-of", outputBase.path,
            "-oj",                       // JSON with millisecond offsets
            // "auto" by default: meetings aren't always in English.
            "-l", AppSettings.shared.transcriptionLanguage,
            "-t", String(threads),
            "-pp",                       // progress on stderr, for the UI
            // No text carried from one 30 s window into the next. Conditioning
            // on its own previous output is how Whisper falls into loops (one
            // phrase 26 times over a quiet stretch) and how it skips speech it
            // has decided is a repeat — on a 19.7-minute test meeting the
            // default lost about 430 words of real conversation. Off, both went
            // away, and it ran faster.
            "-mc", "0",
            "-ml", "0"
        ]

        Log.info("Running whisper-cli with model \(model.lastPathComponent)")
        let progress = onProgress
        // Labelled explicitly: Shell.run now also takes a stdout handler, and an
        // unlabelled trailing closure could bind to the wrong stream. Whisper
        // reports progress on stderr.
        let output = try await Shell.run(
            executable: binary,
            arguments: arguments,
            environment: ToolLocator.enrichedEnvironment(),
            qualityOfService: .utility,
            onStandardErrorLine: { line in
                if let value = Self.parseProgress(line) { progress?(value) }
            })

        guard output.status == 0 else {
            throw ShellError.nonZeroExit("whisper-cli", output.status, output.standardError)
        }

        let segments = try parseSegments(at: jsonFile, energy: energy)
        guard !segments.isEmpty else { throw WhisperError.noTranscription }
        Log.info("Whisper produced \(segments.count) segments")
        return merge(segments)
    }

    // MARK: - Parsing

    private func parseSegments(at jsonFile: URL, energy: EnergyTrack) throws -> [TranscriptSegment] {
        // Once per recording: estimating it scans every frame.
        let echoCoupling = energy.echoCoupling
        if echoCoupling > 0 { Log.info("Speaker labels: removing echo at coupling \(String(format: "%.2f", echoCoupling))") }
        let data = try Data(contentsOf: jsonFile)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["transcription"] as? [[String: Any]]
        else { return [] }

        var segments: [TranscriptSegment] = []
        for entry in entries {
            let text = ((entry["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Self.isNoiseMarker(text) else { continue }

            // whisper.cpp gives millisecond offsets; fall back to the formatted
            // timestamps if that key ever changes shape.
            var start: TimeInterval = 0
            var end: TimeInterval = 0
            if let offsets = entry["offsets"] as? [String: Any],
               let from = (offsets["from"] as? NSNumber)?.doubleValue,
               let to = (offsets["to"] as? NSNumber)?.doubleValue {
                start = from / 1000
                end = to / 1000
            } else if let stamps = entry["timestamps"] as? [String: String] {
                start = Self.parseTimestamp(stamps["from"] ?? "")
                end = Self.parseTimestamp(stamps["to"] ?? "")
            }

            segments.append(TranscriptSegment(start: start,
                                              end: end,
                                              speaker: energy.speaker(from: start, to: end,
                                                                      echoCoupling: echoCoupling),
                                              text: text))
        }
        return segments
    }

    /// Collapses runs of same-speaker segments into readable paragraphs. Whisper
    /// emits a segment every few seconds, which makes for a choppy transcript and
    /// a needlessly long prompt.
    private func merge(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var merged: [TranscriptSegment] = []
        for segment in segments {
            guard var last = merged.last,
                  last.speaker == segment.speaker,
                  segment.start - last.end < 2.0,
                  last.text.count + segment.text.count < 600
            else {
                merged.append(segment)
                continue
            }
            last.text += " " + segment.text
            last.end = segment.end
            merged[merged.count - 1] = last
        }
        return merged
    }

    /// Whisper marks non-speech audio with bracketed tags; they add nothing to a
    /// meeting summary.
    private static func isNoiseMarker(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        guard stripped.count > 1 else { return true }
        let first = stripped.first!
        let last = stripped.last!
        return (first == "[" && last == "]") || (first == "(" && last == ")")
            || (first == "*" && last == "*")
    }

    private static func parseProgress(_ line: String) -> Double? {
        guard line.contains("progress =") else { return nil }
        let digits = line.split(separator: "=").last?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
        guard let digits, let value = Double(digits) else { return nil }
        return min(1.0, max(0.0, value / 100))
    }

    /// Parses "HH:MM:SS,mmm".
    private static func parseTimestamp(_ value: String) -> TimeInterval {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return 0 }
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: - Model discovery

    /// Prefers the most capable model present, so dropping a better `.bin` into
    /// the Models folder upgrades transcription with no code change.
    static func preferredModel() -> URL? {
        if let override = AppSettings.shared.whisperModelPath,
           FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.modelsRoot,
            includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let names = files.filter { $0.pathExtension == "bin" }.map(\.lastPathComponent)
        return pick(names, lowMemory: isLowMemoryMac).map { AppPaths.modelsRoot.appendingPathComponent($0) }
    }

    /// 8 GB or less: the floor for macOS 27, an M1 MacBook Air or Mac mini.
    static var isLowMemoryMac: Bool {
        ProcessInfo.processInfo.physicalMemory <= 8 * 1_073_741_824
    }

    /// The model to use from the files present.
    ///
    /// Ranked by capability first. Within one model, the precision depends on
    /// the machine: full-precision `large-v3-turbo` peaks at 2.2 GB while it
    /// runs, which on an 8 GB Mac — with the call it is transcribing, or the
    /// next one, still open — pushes the system into swap. A quantized copy of
    /// the same model (`-q5_0`, `-q8_0`) is preferred there; anywhere else the
    /// full-precision one wins.
    static func pick(_ names: [String], lowMemory: Bool) -> String? {
        // Ranked best-first; anything unrecognised sorts last but is still usable.
        let ranking = ["large-v3-turbo", "large-v3", "large", "medium", "small", "base", "tiny"]
        func rank(_ name: String) -> Int {
            let name = name.lowercased()
            // Test stubs shipped by Homebrew are too small to transcribe anything.
            if name.contains("for-tests") { return ranking.count + 1 }
            for (index, key) in ranking.enumerated() where name.contains(key) { return index }
            return ranking.count
        }
        func isQuantized(_ name: String) -> Bool {
            name.lowercased().range(of: #"-q\d"#, options: .regularExpression) != nil
        }
        return names.min { left, right in
            let (a, b) = (rank(left), rank(right))
            if a != b { return a < b }
            let (qa, qb) = (isQuantized(left), isQuantized(right))
            if qa != qb { return lowMemory ? qa : qb }
            return left < right
        }
    }
}
