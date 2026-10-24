import Foundation
import Testing
import VoiceTypeCore
@testable import VoiceTypeWhisper

/// The model, from $VOICE_TYPE_TEST_MODEL or the app's default path. These tests skip
/// themselves when it isn't there, since it's 870 MB and never in git.
let testModelPath: String = {
    if let path = ProcessInfo.processInfo.environment["VOICE_TYPE_TEST_MODEL"], !path.isEmpty { return path }
    return VoiceTypePaths.defaultModel.path
}()
let haveModel = FileManager.default.fileExists(atPath: testModelPath)

@Suite(.enabled(if: haveModel, "needs a ggml model at $VOICE_TYPE_TEST_MODEL or the default path"))
struct WhisperEngineTests {
    // mlx-whisper's tokens for " " + the October 2026 word list prompt, which the
    // benchmark's wcpp-q8-vocab runs used.
    static let mlxPromptTokens: [Int32] = [
        2656, 303, 87, 11, 29866, 7967, 11, 12947, 2303, 11, 15549, 87, 11, 46074, 20033, 11,
        44316, 6886, 11, 589, 3599, 279, 11, 11568, 11, 37211, 11, 1726, 313, 11, 8061, 3423,
        543, 11, 691, 2869, 338, 11, 4548, 1756, 299, 11, 36915, 10780, 11, 13445, 78, 11,
        3457, 619, 302, 11, 41132, 610, 13,
    ]

    let engine: WhisperEngine

    init() throws {
        engine = try WhisperEngine(modelPath: testModelPath)
    }

    @Test func promptTokensMatchMlxWhisper() {
        let prompt = VocabularyPrompt.build(VoiceTypeSettings.defaultVocabulary)
        #expect(engine.promptTokens(for: prompt) == Self.mlxPromptTokens)
    }

    @Test func whisperCppsOwnTokenizerSplitsSomeNamesDifferently() {
        // Why WhisperBPETokenizer exists. If this ever passes as equal, whisper.cpp has moved
        // to real byte-pair encoding and the two could be compared again.
        let input = VocabularyPrompt.tokenizerInput(for: VocabularyPrompt.build(VoiceTypeSettings.defaultVocabulary)!)
        let greedy = engine.whisperCppTokenize(input)
        #expect(greedy != Self.mlxPromptTokens)
        #expect(greedy.count == 54)
    }

    @Test func silenceGivesNoTextThroughThePipeline() throws {
        let pipeline = DictationPipeline(
            engine: engine,
            settings: VoiceTypeSettings(vocabulary: VoiceTypeSettings.defaultVocabulary, corrections: .pythonDefaults),
            options: TranscribeOptions(promptTokens: Self.mlxPromptTokens)
        )
        let result = try pipeline.run([Float](repeating: 0, count: 16000))
        #expect(result.status == .flatlineCapture)
    }

    /// Quiet noise, deterministic, so a clip is the same on every run.
    func noise(seconds: Double) -> [Float] {
        var state: UInt32 = 12345
        return (0..<Int(seconds * 16000)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.02
        }
    }

    @Test func aFlagThatIsNeverSetChangesNothing() throws {
        let clip = noise(seconds: 3)
        let options = TranscribeOptions(promptTokens: Self.mlxPromptTokens)
        let plain = try engine.transcribe(clip, options: options)
        let flagged = try engine.transcribe(clip, options: options, abort: AbortFlag())
        #expect(plain.text == flagged.text)
        #expect(plain.segments.map(\.tokenProbs) == flagged.segments.map(\.tokenProbs))
    }

    @Test func anAbortedPreviewStopsBeforeTheEncoder() {
        let flag = AbortFlag()
        flag.set()
        let started = Date()
        #expect(throws: WhisperEngineError.self) { try engine.transcribe(noise(seconds: 5), options: TranscribeOptions(), abort: flag) }
        #expect(Date().timeIntervalSince(started) < 0.2)
    }

    /// whisper.cpp checks the flag between ggml computations, so an encoder pass that has
    /// started runs to the end (about 0.2 s here) and nothing after it does: a key-up costs
    /// the final pass at most one encoder step, as PLAN.md expects.
    @Test func aKeyUpStopsARunningPreviewAfterItsCurrentStep() throws {
        let clip = noise(seconds: 28)
        let flag = AbortFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { flag.set() }
        let started = Date()
        do {
            _ = try engine.transcribe(clip, options: TranscribeOptions(), abort: flag)
            Issue.record("the preview ran to the end")
        } catch let error as WhisperEngineError {
            #expect(error.description == WhisperEngineError.aborted.description)
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
    }
}
