// Audio-level gates, ported from audio_gate.py.
//
// Both of Python's run before Whisper sees a clip. One spots a broken microphone stream, the
// other drops very short, near-silent clips that Whisper would turn into "Thank you.". Native
// adds a third for longer near-silent clips, which also looks at what Whisper typed.

import Foundation

public let sampleRate = 16_000

public enum AudioGate {
    public static let flatlineRecordingMessage = "No microphone audio\nRelease to restart"
    public static let flatlineRecoveryMessage = "No microphone audio\nRestarting Voice Type..."

    /// True when an open microphone stream delivered digital silence.
    ///
    /// A real microphone has a small noise floor even in a quiet room. A sustained stream of
    /// effectively zero-valued samples means Core Audio opened a device that isn't actually
    /// delivering audio, which can happen after macOS wakes.
    public static func isFlatlineAudioCapture(
        durationSec: Double,
        rms: Double,
        peak: Double,
        minDurationSec: Double = 0.5,
        maxRMS: Double = 0.000001,
        maxPeak: Double = 0.00001
    ) -> Bool {
        durationSec >= minDurationSec && rms <= maxRMS && peak <= maxPeak
    }

    /// True when a key hold long enough for a flatline check produced no audio at all: the
    /// stream started but never called back, which AUHAL can do after a wake. Zero samples
    /// make a 0 s clip, which `isFlatlineAudioCapture` (0.5 s minimum) would miss. Native only.
    public static func isMissingAudio(sampleCount: Int, keyHoldSeconds: Double, minHoldSec: Double = 0.5) -> Bool {
        sampleCount == 0 && keyHoldSeconds >= minHoldSec
    }

    /// True for very short, near-silent clips likely to hallucinate.
    ///
    /// On the Yeti, short phrases like "same here" peak around 0.02 to 0.03, while real
    /// silence peaks below 0.008, so the peak limit sits between them. Accidental taps under
    /// 0.4 s keep the stricter limit, since Whisper turns those into "Thank you." and no real
    /// dictation is that short.
    public static func shouldSkipShortLowLevelAudio(
        durationSec: Double,
        rms: Double,
        peak: Double,
        maxDurationSec: Double = 1.0,
        maxRMS: Double = 0.004,
        maxPeak: Double = 0.012,
        tapDurationSec: Double = 0.4,
        tapMaxPeak: Double = 0.03
    ) -> Bool {
        let limit = durationSec < tapDurationSec ? tapMaxPeak : maxPeak
        return durationSec < maxDurationSec && rms < maxRMS && peak < limit
    }

    /// True for a clip of a second or more that never got louder than the room. On its own
    /// this doesn't drop anything: Whisper still runs, and the clip is only dropped if what it
    /// typed is one of its stock silence phrases (`isSilenceHallucination`).
    ///
    /// Native only. whisper.cpp types "Thank you." for these, and its no-speech probability
    /// comes out at about 0, so neither it nor the short-clip gate above (which stops at 1 s)
    /// catches them. Across all 1,865 recordings saved from 14 to 24 October 2026, the seven
    /// clips of 1 s or more that peaked under 0.005 were all silence (1.4 to 11.2 s; whisper.cpp
    /// typed "Thank you." for every one, Python "Thank you.", "!", "C Надо" or a "Flare
    /// Flare..." loop), while the quietest real dictation of 1 s or more peaked at 0.0138
    /// ("Sure.", 1.1 s) and the quietest of any length at 0.0126. 0.008 sits between them.
    ///
    /// The level alone isn't safe, though: the margin is under 5 dB. With the Yeti's gain 6 dB
    /// lower, 6 of the 1,826 saved dictations would fall under it, 21 at 8 dB and 58 at 10 dB.
    /// Asking what Whisper heard keeps those, since real words aren't "Thank you.".
    public static func isLongNearSilentClip(
        durationSec: Double,
        peak: Double,
        minDurationSec: Double = 1.0,
        maxPeak: Double = 0.008
    ) -> Bool {
        durationSec >= minDurationSec && peak < maxPeak
    }

    /// What Whisper makes up for a clip with nothing in it, lower case, punctuation dropped:
    /// YouTube sign-offs from its training data, and "you". A quiet real "Sure." or "Okay." is
    /// deliberately not here.
    public static let silencePhrases: Set<String> = [
        "you", "thank you", "thanks", "thank you very much", "thank you so much",
        "thanks for watching", "thank you for watching", "thank you so much for watching",
        "thanks for watching and see you next time", "please subscribe", "bye", "bye bye",
        "subtitles by the amara org community",
    ]

    /// True when `text` is only Whisper's silence phrases (once or repeated), or is mostly not
    /// Latin letters (punctuation, "!", or a stray "C Надо"; Whisper is told the speech is
    /// English). Only used together with `isLongNearSilentClip`, so a real "Thank you." spoken
    /// at a normal level is still typed.
    public static func isSilenceHallucination(_ text: String) -> Bool {
        let scalars = text.lowercased().unicodeScalars
        let latin = scalars.filter { ("a"..."z").contains($0) || ("\u{E0}"..."\u{FF}").contains($0) }.count
        let otherLetters = scalars.filter { CharacterSet.letters.contains($0) }.count - latin
        guard latin > 0 && latin >= otherLetters else { return true }
        let words = scalars
            .map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "'" ? Character($0) : " " }
            .split(separator: " ").map { String($0).replacingOccurrences(of: "'", with: "") }.filter { !$0.isEmpty }
        // Longest phrase first, so "thank you very much" isn't read as "thank you" + junk.
        let phrases = silencePhrases.map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
        var rest = words[...]
        while !rest.isEmpty {
            guard let phrase = phrases.first(where: { rest.starts(with: $0) }) else { return false }
            rest = rest.dropFirst(phrase.count)
        }
        return true
    }
}

/// Duration, RMS and peak of a clip, computed bit for bit as the Python app does.
///
/// The gates compare these against fixed thresholds, so a clip sitting right on a threshold
/// has to land on the same side in both apps. Python computes them in float32 with numpy
/// (`np.sqrt(np.mean(audio ** 2))` and `np.max(np.abs(audio))`), and numpy sums float32
/// arrays pairwise, so the RMS here repeats numpy's exact order of additions.
public struct AudioLevels: Equatable, Sendable {
    public let durationSec: Double
    public let rms: Double
    public let peak: Double

    public init(durationSec: Double, rms: Double, peak: Double) {
        self.durationSec = durationSec
        self.rms = rms
        self.peak = peak
    }

    public init(samples: [Float]) {
        // An empty clip counts as silent, as in voice-type.py's _finish_dictation.
        guard !samples.isEmpty else {
            self.init(durationSec: 0, rms: 0, peak: 0)
            return
        }
        let squares = samples.map { $0 * $0 }
        let sum = squares.withUnsafeBufferPointer { numpyPairwiseSum($0[...]) }
        // np.mean divides the float32 sum by an intp count, which numpy does in float64
        // before casting the result back to float32. np.sqrt then stays in float32.
        let mean = Float(Double(sum) / Double(samples.count))
        var peak: Float = 0
        for sample in samples { peak = max(peak, abs(sample)) }
        self.init(
            durationSec: Double(samples.count) / Double(sampleRate),
            rms: Double(mean.squareRoot()),
            peak: Double(peak)
        )
    }
}

/// numpy's pairwise_sum for float32 (numpy/_core/src/umath/loops_utils.h.src): a plain loop
/// under 8 values, eight interleaved accumulators up to 128, and halving above that.
func numpyPairwiseSum(_ a: Slice<UnsafeBufferPointer<Float>>) -> Float {
    let n = a.count
    let base = a.startIndex
    if n < 8 {
        var res: Float = 0
        for i in 0..<n { res += a[base + i] }
        return res
    } else if n <= 128 {
        var r = (0..<8).map { a[base + $0] }
        var i = 8
        while i < n - (n % 8) {
            for k in 0..<8 { r[k] += a[base + i + k] }
            i += 8
        }
        var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
        while i < n {
            res += a[base + i]
            i += 1
        }
        return res
    } else {
        var n2 = n / 2
        n2 -= n2 % 8
        return numpyPairwiseSum(a[base..<base + n2]) + numpyPairwiseSum(a[(base + n2)...])
    }
}
