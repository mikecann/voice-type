import Foundation
import Testing
@testable import VoiceTypeCore

// Ported from AudioGateTests in tests/test_audio_gate.py.
struct AudioGateTests {
    @Test func skipsShortNearSilentAudio() {
        #expect(AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.4, rms: 0.001, peak: 0.01))
    }

    @Test func detectsLongDigitalFlatline() {
        #expect(AudioGate.isFlatlineAudioCapture(durationSec: 4.2, rms: 0.0, peak: 0.0))
    }

    @Test func shortEmptyCaptureIsNotTreatedAsBrokenStream() {
        #expect(!AudioGate.isFlatlineAudioCapture(durationSec: 0.05, rms: 0.0, peak: 0.0))
    }

    @Test func longQuietAudioIsNotADigitalFlatline() {
        #expect(!AudioGate.isFlatlineAudioCapture(durationSec: 4.2, rms: 0.001, peak: 0.01))
    }

    @Test func flatlineMessagesExplainTheRecovery() {
        #expect(AudioGate.flatlineRecordingMessage == "No microphone audio\nRelease to restart")
        #expect(AudioGate.flatlineRecoveryMessage == "No microphone audio\nRestarting Voice Type...")
    }

    @Test func keepsLongQuietAudio() {
        #expect(!AudioGate.shouldSkipShortLowLevelAudio(durationSec: 1.2, rms: 0.001, peak: 0.01))
    }

    @Test func keepsShortQuietlySpokenPhrase() {
        // Levels of a real "same here" that the old 0.03 peak limit dropped.
        #expect(!AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.69, rms: 0.0036, peak: 0.0249))
    }

    @Test func skipsShortRoomNoise() {
        #expect(AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.59, rms: 0.0006, peak: 0.0079))
    }

    @Test func skipsQuietAccidentalTap() {
        // A 0.14 s tap that Whisper transcribed as "Thank you."
        #expect(AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.14, rms: 0.0036, peak: 0.0189))
    }

    @Test func keepsShortAudioWithClearPeak() {
        #expect(!AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.4, rms: 0.001, peak: 0.2))
    }

    // Not in the Python tests, but the thresholds are strict comparisons there.
    @Test func thresholdsAreStrict() {
        #expect(!AudioGate.shouldSkipShortLowLevelAudio(durationSec: 1.0, rms: 0.001, peak: 0.001))
        #expect(!AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.5, rms: 0.004, peak: 0.001))
        #expect(!AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.5, rms: 0.001, peak: 0.012))
        #expect(AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.39, rms: 0.001, peak: 0.029))
        #expect(!AudioGate.shouldSkipShortLowLevelAudio(durationSec: 0.4, rms: 0.001, peak: 0.029))
        #expect(AudioGate.isFlatlineAudioCapture(durationSec: 0.5, rms: 0.000001, peak: 0.00001))
    }
}

// Expected values are what voice-type.py computes with numpy 2.4.6 for the same float32
// samples: float(np.sqrt(np.mean(audio ** 2))) and float(np.max(np.abs(audio))).
struct AudioLevelsTests {
    @Test func emptyAudioIsSilent() {
        #expect(AudioLevels(samples: []) == AudioLevels(durationSec: 0, rms: 0, peak: 0))
    }

    @Test func matchesNumpyOnAFewSamples() {
        let levels = AudioLevels(samples: [0.25, -0.5, 0.125])
        #expect(levels.durationSec == 0.0001875)
        #expect(levels.rms == 0.33071890473365784)
        #expect(levels.peak == 0.5)
    }

    @Test func matchesNumpyOnAQuietRamp() {
        let samples = (0..<1000).map { Float($0 % 17) * (1 / 1024) - 0.0078125 }
        let levels = AudioLevels(samples: samples)
        #expect(levels.durationSec == 0.0625)
        #expect(levels.rms == 0.004776478745043278)
        #expect(levels.peak == 0.0078125)
    }

    @Test func matchesNumpyOnOneSecond() {
        let levels = AudioLevels(samples: (0..<16000).map { Float($0 % 37) * (1 / 4096) })
        #expect(levels.durationSec == 1.0)
        #expect(levels.rms == 0.005107381381094456)
        #expect(levels.peak == 0.0087890625)
    }

    @Test func sumsPairwiseLikeNumpy() {
        // Long enough for float32 rounding to pile up: a plain running sum gives an RMS of
        // 0.2821824848651886 here, numpy's pairwise sum 0.2821733355522156.
        let samples = (0..<100_000).map { Float(($0 * 7919) % 1000) / 1024 - 0.5 }
        let levels = AudioLevels(samples: samples)
        #expect(levels.durationSec == 6.25)
        #expect(levels.rms == 0.2821733355522156)
        #expect(levels.peak == 0.5)
    }
}

/// The native-only check for silent clips of a second or more, run against the levels of
/// every recording saved from 14 to 24 October 2026 (Fixtures/recording-levels.json: duration,
/// rms and peak as numpy computed them, and a label, with no text). "silence" marks the seven
/// clips whisper.cpp typed as "Thank you.", "skipped" the ones Python's short-clip gate dropped
/// at the time, "speech" everything Python typed.
struct NearSilenceGateTests {
    struct Row: Decodable {
        let seconds: Double
        let rms: Double
        let peak: Double
        let label: String
    }

    func rows() throws -> [Row] {
        let url = try #require(Bundle.module.url(forResource: "recording-levels", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
    }

    @Test func theThankYouClipsAreNearSilent() {
        // The three 1a found: 1.39 s, 2.22 s and 2.50 s.
        #expect(AudioGate.isLongNearSilentClip(durationSec: 1.392, peak: 0.0026))
        #expect(AudioGate.isLongNearSilentClip(durationSec: 2.224, peak: 0.00024))
        #expect(AudioGate.isLongNearSilentClip(durationSec: 2.496, peak: 0.00193))
    }

    @Test func theQuietestRealDictationsAreNot() {
        #expect(!AudioGate.isLongNearSilentClip(durationSec: 1.104, peak: 0.013764457777142525))  // "Sure."
        #expect(!AudioGate.isLongNearSilentClip(durationSec: 4.848, peak: 0.014085972681641579))
    }

    @Test func leavesClipsUnderASecondToThePythonGate() {
        #expect(!AudioGate.isLongNearSilentClip(durationSec: 0.99, peak: 0.0001))
    }

    @Test func knowsWhispersSilencePhrases() {
        for text in ["Thank you.", "thank you", "Thanks for watching!", "Thank you for watching.", "you", "You", "!", "...", "",
                     "Надо", "C Надо", "Thank you. Thank you.", "Thank you very much.", "Bye-bye."] {
            #expect(AudioGate.isSilenceHallucination(text), "\(text)")
        }
        for text in ["Sure.", "Okay.", "Thank you, Ian.", "Thanks for the review", "Yes", "Port it to CUDA.", "Café"] {
            #expect(!AudioGate.isSilenceHallucination(text), "\(text)")
        }
    }

    @Test func neverDropsASavedDictationBeforeWhisper() throws {
        let rows = try rows()
        #expect(rows.count == 1865)
        var silent = 0, shortSkipped = 0, keptSinceEight = 0
        for row in rows {
            let levels = AudioLevels(durationSec: row.seconds, rms: row.rms, peak: row.peak)
            let status = DictationPipeline.gate(levels)?.status
            switch row.label {
            case "speech":
                #expect(status == nil || status == .tooShort, "dropped a dictation: \(row.seconds) s, peak \(row.peak)")
                #expect(!AudioGate.isLongNearSilentClip(durationSec: row.seconds, peak: row.peak))
            case "silence":
                // These go to Whisper, and its "Thank you." is what drops them.
                #expect(status == nil)
                #expect(AudioGate.isLongNearSilentClip(durationSec: row.seconds, peak: row.peak))
                silent += 1
            case "skipped":
                // Two of these were dropped by the 0.03 peak limit before PR #8, which today's
                // gate (Python's and this one) keeps.
                #expect(row.seconds < 1)
                if status == .skippedLowLevel { shortSkipped += 1 } else { keptSinceEight += 1 }
            default:
                break
            }
        }
        #expect(silent == 7)
        #expect(shortSkipped == 27)
        #expect(keptSinceEight == 2)
    }

    /// Why the level alone isn't enough: with the gain turned down, real dictations fall under
    /// it. Each one still gets typed, since Whisper hears words in it, while the seven silent
    /// clips (whisper.cpp's "Thank you.") are still dropped.
    @Test func quieterGainStillTypesEveryDictation() throws {
        let rows = try rows()
        for (db, expected) in [(6.0, 6), (8.0, 21), (10.0, 58)] {
            let gain = pow(10, -db / 20)
            var underTheLevel = 0
            for row in rows where row.label == "speech" || row.label == "silence" {
                let levels = AudioLevels(durationSec: row.seconds, rms: row.rms * gain, peak: row.peak * gain)
                let engine = FakeEngine([row.label == "speech" ? "Sure." : "Thank you."])
                let pipeline = DictationPipeline(engine: engine, settings: VoiceTypeSettings(vocabulary: nil, corrections: Corrections([])), options: TranscribeOptions())
                guard DictationPipeline.gate(levels) == nil else { continue }
                let result = try pipeline.transcribe([], levels: levels)
                if row.label == "speech" {
                    if AudioGate.isLongNearSilentClip(durationSec: levels.durationSec, peak: levels.peak) { underTheLevel += 1 }
                    #expect(result.text == "Sure.")
                } else {
                    #expect(result.status == .skippedNearSilent)
                }
            }
            #expect(underTheLevel == expected, "\(db) dB")
        }
    }
}
