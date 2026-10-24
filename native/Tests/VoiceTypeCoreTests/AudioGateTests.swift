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
