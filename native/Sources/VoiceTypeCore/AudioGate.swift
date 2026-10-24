// Audio-level gates, ported from audio_gate.py.
//
// Both run before Whisper sees a clip. One spots a broken microphone stream, the other drops
// very short, near-silent clips that Whisper would turn into "Thank you.".

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
