import Foundation
import Speech
import AVFoundation

/// Live, on-device transcription using Apple's SpeechAnalyzer stack (macOS 26+).
///
/// This exists purely so you can watch the conversation scroll by while it
/// happens. The authoritative transcript comes from Whisper afterwards, so every
/// failure here is non-fatal: if the model is missing or the locale is
/// unsupported we log it, leave the live pane empty, and still record audio.
actor LiveTranscriber {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AnalyzerInputConverter?
    private var resultsTask: Task<Void, Never>?
    private var reservedLocale: Locale?

    private var finalizedText = ""
    private var volatileText = ""
    private var started = false
    /// Set when `finish()` arrives while `start()` is still suspended — a short
    /// recording stopped during a first-run model download. `start()` checks it
    /// after each await and tears down instead of starting an analyzer nobody
    /// will ever finish.
    private var finishRequested = false

    /// Emits the full text so far (finalized plus the in-flight tail).
    private var onUpdate: (@Sendable (String) -> Void)?

    var currentText: String {
        (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prepares models and begins analysis. Throws if live transcription is
    /// unavailable; callers should treat that as a degraded mode, not an error.
    func start(onUpdate: @escaping @Sendable (String) -> Void) async throws {
        guard !started else { return }
        self.onUpdate = onUpdate

        guard SpeechTranscriber.isAvailable else {
            throw LiveTranscriptionError.unavailable("Speech transcription is not available on this Mac.")
        }

        // Prefer the user's own locale, falling back to any supported one.
        // A fixed transcription language wins over the system locale.
        let chosen = AppSettings.shared.transcriptionLanguage
        let preferred = chosen == "auto" ? Locale.current : Locale(identifier: chosen)
        let matched = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
        let fallback = await SpeechTranscriber.supportedLocales.first
        guard let locale = matched ?? fallback else {
            throw LiveTranscriptionError.unavailable("No supported transcription locale was found.")
        }

        // .progressiveTranscription streams volatile partial results, which is
        // what makes the live pane feel responsive rather than arriving in
        // sentence-sized lumps.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        try await installAssetsIfNeeded(for: transcriber, locale: locale)
        try await abandonIfFinished()

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveTranscriptionError.unavailable("No compatible audio format for the transcriber.")
        }
        converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: stream)
        try await abandonIfFinished()

        resultsTask = Task { [weak self] in
            await self?.consumeResults(from: transcriber)
        }

        started = true
        Log.info("Live transcription started (\(locale.identifier))")
    }

    /// Feeds mixed 16 kHz mono samples from the capture engine.
    func append(_ samples: [Float]) {
        guard started, let continuation, let converter, !samples.isEmpty else { return }
        guard let buffer = Self.makeBuffer(from: samples) else { return }
        do {
            for input in try converter.convert(buffer, at: nil) {
                continuation.yield(input)
            }
        } catch {
            Log.warn("Live transcription convert failed: \(error.localizedDescription)")
        }
    }

    /// Closes the input, drains remaining results, and returns the final text.
    func finish() async -> String {
        guard started else {
            finishRequested = true
            return currentText
        }
        started = false

        if let converter, let continuation {
            // Flush the converter's tail so trailing audio isn't dropped.
            for input in (try? converter.flush()) ?? [] {
                continuation.yield(input)
            }
        }
        continuation?.finish()
        continuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.warn("Live transcription finalize failed: \(error.localizedDescription)")
            await analyzer?.cancelAndFinishNow()
        }

        _ = await resultsTask?.result
        resultsTask = nil
        analyzer = nil
        transcriber = nil

        if let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }

        // Fold any trailing volatile text in, so nothing spoken is lost.
        finalizedText = currentText
        volatileText = ""
        Log.info("Live transcription finished (\(finalizedText.count) chars)")
        return finalizedText
    }

    // MARK: - Internals

    private func abandonIfFinished() async throws {
        guard finishRequested else { return }
        continuation?.finish()
        continuation = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        if let reservedLocale {
            _ = await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
        Log.info("Live transcription abandoned: the recording stopped before it started")
        throw LiveTranscriptionError.abandoned
    }

    private func consumeResults(from transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    // Keep spacing sane without double-spacing at boundaries.
                    if !finalizedText.isEmpty, !finalizedText.hasSuffix(" ") {
                        finalizedText += " "
                    }
                    finalizedText += text
                    volatileText = ""
                } else {
                    volatileText = text
                }
                onUpdate?(currentText)
            }
        } catch {
            Log.warn("Live transcription stream ended: \(error.localizedDescription)")
        }
    }

    private func installAssetsIfNeeded(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            break
        case .supported, .downloading:
            Log.info("Downloading on-device speech model for \(locale.identifier)…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                Log.info("Speech model installed")
            }
        case .unsupported:
            throw LiveTranscriptionError.unavailable("No on-device speech model is available for \(locale.identifier).")
        @unknown default:
            break
        }

        // Reserving keeps the model resident for the length of the meeting.
        if (try? await AssetInventory.reserve(locale: locale)) == true {
            reservedLocale = locale
        }
    }

    private static func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = Resampler.targetFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

enum LiveTranscriptionError: LocalizedError {
    case unavailable(String)
    /// The recording ended before live text got going; not worth a warning.
    case abandoned

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .abandoned: return "The recording stopped before live text started."
        }
    }
}
