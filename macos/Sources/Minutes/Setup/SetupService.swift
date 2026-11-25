import Foundation
import Combine
import AppKit
import CryptoKit

/// Detects missing dependencies and repairs what it can.
///
/// The app needs three things it cannot bundle: whisper-cli (GPL-licensed and
/// Homebrew-managed), a Whisper model (0.6–1.6 GB), and the claude CLI (which also
/// carries the user's sign-in). Without this, a fresh Mac finds out about each
/// one by having a meeting fail at the end — the worst possible moment.
///
/// What can be fixed silently is fixed from here: whisper-cli through Homebrew,
/// the model by direct download. The claude CLI is deliberately only *pointed
/// at*: it wants a sign-in that must happen in the user's own terminal, and
/// piping an install script to a shell on their behalf is not this app's call.
@MainActor
final class SetupService: ObservableObject {
    enum ItemState: Equatable {
        case checking
        case ready(detail: String)
        case missing(detail: String)
        case fixing(progress: String)
        case failed(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
        var isFixing: Bool { if case .fixing = self { return true }; return false }
    }

    @Published private(set) var whisper: ItemState = .checking
    @Published private(set) var model: ItemState = .checking
    @Published private(set) var claude: ItemState = .checking
    @Published private(set) var homebrewPresent = false

    /// True when something the recording pipeline depends on is absent.
    var needsSetup: Bool {
        [whisper, model, claude].contains { if case .missing = $0 { return true }
                                            if case .failed = $0 { return true }
                                            return false }
    }

    /// A Whisper model the app knows how to fetch and verify.
    struct ModelDownload {
        let name: String
        /// SHA-256 as published by Hugging Face (its LFS `X-Linked-ETag`). The
        /// size floor only catches an error page; a truncated or corrupted
        /// model otherwise loads fine and fails at the end of a meeting.
        let sha256: String
        /// Sanity floor — a truncated download must not be mistaken for a model.
        let minimumBytes: Int
        /// For the progress line.
        let approximateSize: String

        var url: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)")!
        }
    }

    static let fullModel = ModelDownload(
        name: "ggml-large-v3-turbo.bin",
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        minimumBytes: 1_000_000_000,
        approximateSize: "1.6 GB")

    /// The same model, 5-bit quantized. Measured on a 19.7-minute meeting:
    /// 1.09 GB peak against 2.22 GB, 30 s against 40 s, and a transcript as
    /// close to full precision's as one decoding setting is to another.
    static let quantizedModel = ModelDownload(
        name: "ggml-large-v3-turbo-q5_0.bin",
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        minimumBytes: 500_000_000,
        approximateSize: "574 MB")

    /// What a new install downloads: the quantized copy on 8 GB Macs, where
    /// full precision's extra gigabyte comes out of the call being recorded.
    static var modelToDownload: ModelDownload {
        WhisperRefiner.isLowMemoryMac ? quantizedModel : fullModel
    }

    private var downloader: ModelDownloader?

    // MARK: - Checks

    func refresh() async {
        homebrewPresent = ToolLocator.find("brew") != nil

        // A row mid-install keeps its state. Resetting it hid the download's
        // progress and Cancel button, and brought back an Install button that
        // started a second, competing `brew install`.
        if !whisper.isFixing {
            whisper = ToolLocator.find("whisper-cli").map { .ready(detail: $0.path) }
                ?? .missing(detail: homebrewPresent
                    ? "Transcribes recordings. One click installs it with Homebrew."
                    : "Transcribes recordings. Installing it needs Homebrew, which is not on this Mac.")
        }

        if model.isFixing || downloader != nil {
            // Still downloading.
        } else if let found = WhisperRefiner.preferredModel() {
            let size = (try? FileManager.default.attributesOfItem(atPath: found.path)[.size] as? Int) ?? 0
            model = .ready(detail: "\(found.lastPathComponent) (\(size / 1_000_000) MB)")
        } else {
            model = .missing(detail: "The speech model Whisper runs (\(Self.modelToDownload.approximateSize), downloaded once).")
        }

        claude = await Self.checkClaude()
    }

    /// Reuses the same auth parsing the Settings connection row relies on, so
    /// setup and Settings can never disagree about the claude CLI.
    private static func checkClaude() async -> ItemState {
        guard let binary = ToolLocator.find("claude") else {
            return .missing(detail: "Writes the meeting notes on your Claude subscription. Install Claude Code, then run `claude` once in a terminal to sign in.")
        }
        do {
            let output = try await Shell.run(executable: binary,
                                           arguments: ["auth", "status"],
                                           environment: ToolLocator.enrichedEnvironment(),
                                           currentDirectory: AppPaths.supportRoot,
                                           timeout: 20)
            guard let status = ClaudeConnection.parseAuthStatus(output.standardOutput) else {
                return .failed("The claude CLI is installed but its status could not be read.")
            }
            if status.loggedIn {
                let who = [status.account.email, status.account.subscription]
                    .compactMap { $0 }.joined(separator: " · ")
                return .ready(detail: who.isEmpty ? binary.path : who)
            }
            return .missing(detail: "Claude Code is installed but signed out. Run `claude auth login` in a terminal.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Fixes

    func installWhisper() async {
        guard !whisper.isFixing, let brew = ToolLocator.find("brew") else { return }
        whisper = .fixing(progress: "Installing whisper-cpp with Homebrew…")

        var environment = ToolLocator.enrichedEnvironment()
        // Keep brew from updating the world or waiting on a prompt; this is a
        // GUI context with nobody at a terminal to answer it.
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        environment["NONINTERACTIVE"] = "1"

        do {
            let output = try await Shell.run(
                executable: brew,
                arguments: ["install", "whisper-cpp"],
                environment: environment,
                timeout: 900,
                onStandardErrorLine: { [weak self] line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    Task { @MainActor in
                        if case .fixing = self?.whisper {
                            self?.whisper = .fixing(progress: String(trimmed.prefix(90)))
                        }
                    }
                })
            // Re-detect rather than trusting the exit code: a partial cache in
            // ToolLocator would report stale state.
            ToolLocator.invalidate("whisper-cli")
            if let found = ToolLocator.find("whisper-cli") {
                whisper = .ready(detail: found.path)
                Log.info("whisper-cli installed at \(found.path)")
            } else {
                let tail = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                whisper = .failed(tail.isEmpty
                    ? "Homebrew finished but whisper-cli was not found."
                    : String(tail.suffix(200)))
            }
        } catch {
            whisper = .failed(error.localizedDescription)
        }
    }

    func downloadModel() {
        guard downloader == nil else { return }
        model = .fixing(progress: "Starting download…")

        let choice = Self.modelToDownload
        let downloader = ModelDownloader(
            url: choice.url,
            destination: AppPaths.modelsRoot.appendingPathComponent(choice.name),
            minimumBytes: choice.minimumBytes,
            sha256: choice.sha256,
            onProgress: { [weak self] fraction, received in
                Task { @MainActor in
                    guard case .fixing = self?.model else { return }
                    let mb = received / 1_000_000
                    self?.model = .fixing(progress: fraction > 0
                        ? String(format: "Downloading — %d%% (%d MB)", Int(fraction * 100), mb)
                        : "Downloading — \(mb) MB")
                }
            },
            onCompletion: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloader = nil
                    if let error {
                        self.model = .failed(error)
                    } else {
                        await self.refresh()
                    }
                }
            })
        self.downloader = downloader
        downloader.start()
    }

    func cancelModelDownload() {
        downloader?.cancel()
        downloader = nil
        model = .missing(detail: "Download cancelled. The speech model Whisper runs (\(Self.modelToDownload.approximateSize)).")
    }

    func openClaudeCodePage() {
        NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
    }
}

/// Downloads the Whisper model with progress, writing to a `.part` file and
/// renaming only on success, so a half-download can never be mistaken for a
/// model — WhisperRefiner picks up any `.bin` it finds.
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let minimumBytes: Int
    private let sha256: String
    private let onProgress: @Sendable (Double, Int) -> Void
    private let onCompletion: @Sendable (String?) -> Void
    private var session: URLSession?

    init(url: URL, destination: URL, minimumBytes: Int, sha256: String,
         onProgress: @escaping @Sendable (Double, Int) -> Void,
         onCompletion: @escaping @Sendable (String?) -> Void) {
        self.url = url
        self.destination = destination
        self.minimumBytes = minimumBytes
        self.sha256 = sha256
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func start() {
        AppPaths.ensureDirectories()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        onProgress(fraction, Int(totalBytesWritten))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        defer { session.finishTasksAndInvalidate() }
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                onCompletion("The download failed: the server answered HTTP \(http.statusCode).")
                return
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0
            guard size >= minimumBytes else {
                onCompletion("The download was only \(size / 1_000_000) MB — expected at least \(minimumBytes / 1_000_000) MB. The server may have returned an error page.")
                return
            }
            // `location` is deleted when this delegate call returns, so it is
            // hashed here, synchronously, on the session's background queue.
            let digest = try Self.sha256Hex(of: location)
            guard digest == sha256 else {
                Log.error("Model checksum mismatch: got \(digest)")
                onCompletion("The downloaded model is corrupted (checksum mismatch). Try the download again.")
                return
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            Log.info("Whisper model downloaded to \(destination.path)")
            onCompletion(nil)
        } catch {
            onCompletion(error.localizedDescription)
        }
    }

    /// Streams the file through SHA-256 so the model never sits in memory.
    private static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        onCompletion(error.localizedDescription)
    }
}
