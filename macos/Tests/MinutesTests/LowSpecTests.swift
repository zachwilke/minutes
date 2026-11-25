import Foundation
import Testing
@testable import Minutes

/// Choices made for the smallest Mac Minutes runs on: an 8 GB M1.
struct LowSpecTests {

    // MARK: - Whisper model

    private let both = ["ggml-large-v3-turbo.bin", "ggml-large-v3-turbo-q5_0.bin"]

    @Test func lowMemoryPrefersTheQuantizedCopyOfTheSameModel() {
        #expect(WhisperRefiner.pick(both, lowMemory: true) == "ggml-large-v3-turbo-q5_0.bin")
    }

    @Test func otherwiseFullPrecisionWins() {
        #expect(WhisperRefiner.pick(both, lowMemory: false) == "ggml-large-v3-turbo.bin")
    }

    /// Precision only breaks ties: a quantized small model never beats a
    /// full-precision large one, however little memory there is.
    @Test func capabilityOutranksPrecision() {
        let names = ["ggml-small-q5_0.bin", "ggml-large-v3-turbo.bin"]
        #expect(WhisperRefiner.pick(names, lowMemory: true) == "ggml-large-v3-turbo.bin")
    }

    @Test func aLoneModelIsUsedWhateverItsPrecision() {
        #expect(WhisperRefiner.pick(["ggml-large-v3-turbo.bin"], lowMemory: true) == "ggml-large-v3-turbo.bin")
        #expect(WhisperRefiner.pick(["ggml-large-v3-turbo-q8_0.bin"], lowMemory: false) == "ggml-large-v3-turbo-q8_0.bin")
    }

    @Test func homebrewTestStubsSortLast() {
        let names = ["for-tests-ggml-large-v3-turbo.bin", "ggml-base.bin"]
        #expect(WhisperRefiner.pick(names, lowMemory: false) == "ggml-base.bin")
        #expect(WhisperRefiner.pick([], lowMemory: false) == nil)
    }

    // MARK: - Disk space

    @Test func plentyOfSpaceSaysNothing() {
        #expect(RecordingCoordinator.lowDiskWarning(available: 20_000_000_000) == nil)
    }

    /// 32 kB a second of 16 kHz mono: 192 MB is 100 minutes.
    @Test func lowSpaceSaysHowManyMinutesAreLeft() throws {
        let warning = try #require(RecordingCoordinator.lowDiskWarning(available: 192_000_000))
        #expect(warning.contains("about 100 minutes"))
    }
}
