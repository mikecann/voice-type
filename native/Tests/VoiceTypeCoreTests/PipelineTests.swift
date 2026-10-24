import Testing
@testable import VoiceTypeCore

final class FakeEngine: SpeechEngine {
    var segments: [String]
    private(set) var calls: [(samples: Int, options: TranscribeOptions)] = []

    init(_ segments: [String]) { self.segments = segments }

    func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
        calls.append((samples.count, options))
        return Transcript(segments: segments.map {
            TranscriptSegment(text: $0, startSec: 0, endSec: 0, noSpeechProb: 0, tokenProbs: [])
        })
    }
}

struct PipelineTests {
    /// A clip that passes every gate: loud enough, long enough.
    func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(sampleRate))).map { $0 % 2 == 0 ? 0.1 : -0.1 }
    }

    func pipeline(_ engine: FakeEngine, corrections: Corrections = .pythonDefaults) -> DictationPipeline {
        DictationPipeline(
            engine: engine,
            settings: VoiceTypeSettings(vocabulary: ["Convex"], corrections: corrections),
            options: TranscribeOptions(promptTokens: [1, 2, 3])
        )
    }

    @Test func flatlineNeverReachesWhisper() throws {
        let engine = FakeEngine(["Thank you."])
        let result = try pipeline(engine).run([Float](repeating: 0, count: 16000))
        #expect(result.status == .flatlineCapture)
        #expect(result.text == "")
        #expect(engine.calls.isEmpty)
    }

    @Test func nearSilentShortClipIsSkipped() throws {
        // The near-silent "Thank you." clips: under a second, rms and peak tiny.
        let engine = FakeEngine(["Thank you."])
        let quiet = (0..<9000).map { Float($0 % 5) * 0.001 }
        let result = try pipeline(engine).run(quiet)
        #expect(result.status == .skippedLowLevel)
        #expect(result.status.pythonStatus == "skipped_low_level")
        #expect(engine.calls.isEmpty)
    }

    @Test func emptyAudioIsSkippedAsNearSilent() throws {
        let engine = FakeEngine(["x"])
        #expect(try pipeline(engine).run([]).status == .skippedLowLevel)
        #expect(engine.calls.isEmpty)
    }

    @Test func underAThirdOfASecondIsIgnored() throws {
        let engine = FakeEngine(["Yes."])
        let result = try pipeline(engine).run(speech(seconds: 0.29))
        #expect(result.status == .tooShort)
        #expect(result.status.pythonStatus == "finished_without_text")
        #expect(engine.calls.isEmpty)
    }

    @Test func joinsSegmentsThenAppliesTheLoopGuardThenCorrections() throws {
        let engine = FakeEngine([" Port it to kuda. ", "", " Then " + String(repeating: "ship ", count: 8)])
        let result = try pipeline(engine).run(speech(seconds: 5))
        #expect(result.rawTranscript == "Port it to kuda. Then " + Array(repeating: "ship", count: 8).joined(separator: " "))
        #expect(result.text == "Port it to CUDA. Then ship")
        #expect(result.status == .completed)
        #expect(engine.calls.first?.options.promptTokens == [1, 2, 3])
    }

    @Test func loopGuardUsesTheClipsDuration() throws {
        // Four repeats in half a second is faster than anyone talks; in 2 s it's fine.
        let engine = FakeEngine(["Call us Call us Call us Call us"])
        #expect(try pipeline(engine).run(speech(seconds: 0.5)).status == .finishedWithoutText)
        #expect(try pipeline(engine).run(speech(seconds: 2)).text == "Call us Call us Call us Call us")
    }

    @Test func correctionsRunAfterTheLoopGuard() throws {
        // "kuda" becomes "CUDA" only after the loop of "kuda" has been collapsed.
        let engine = FakeEngine(["I like " + String(repeating: "kuda ", count: 8)])
        #expect(try pipeline(engine).run(speech(seconds: 9)).text == "I like CUDA")
    }

    @Test func engineOnlySkipsTheGatesAndGuard() throws {
        let engine = FakeEngine([" Thank you. "])
        let result = try pipeline(engine).runEngineOnly([Float](repeating: 0, count: 16000))
        #expect(result.text == "Thank you.")
        #expect(engine.calls.count == 1)
    }
}

struct NearSilencePipelineTests {
    // 2.2 s of room noise peaking at 0.002.
    let room = (0..<35_200).map { Float(($0 * 7919) % 41) / 20 * 0.001 - 0.001 }

    func pipeline(_ engine: FakeEngine) -> DictationPipeline {
        DictationPipeline(engine: engine, settings: VoiceTypeSettings(vocabulary: nil, corrections: Corrections([])), options: TranscribeOptions())
    }

    @Test func aLongSilentClipThatWhisperCallsThankYouIsDropped() throws {
        let engine = FakeEngine(["Thank you."])
        let result = try pipeline(engine).run(room)
        #expect(result.status == .skippedNearSilent)
        #expect(result.status.pythonStatus == "skipped_low_level")
        #expect(result.text.isEmpty)
        #expect(result.rawTranscript == "Thank you.")
        #expect(engine.calls.count == 1)
    }

    @Test func quietRealWordsAreStillTyped() throws {
        let result = try pipeline(FakeEngine(["Sure."])).run(room)
        #expect(result.status == .completed)
        #expect(result.text == "Sure.")
    }

    @Test func aRealThankYouAtANormalLevelIsTyped() throws {
        let speech = (0..<32_000).map { $0 % 2 == 0 ? Float(0.1) : -0.1 }
        let result = try pipeline(FakeEngine(["Thank you."])).run(speech)
        #expect(result.text == "Thank you.")
    }
}
