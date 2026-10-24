// Whisper sometimes gets stuck on near-silent or clipped audio and repeats one word or phrase
// hundreds of times ("making making making...", "Call us Call us..."), even with its own
// fallbacks. Nobody repeats a phrase 8 times back to back in dictation, and 4 times only
// counts when it came out faster than anyone talks, so "no, no, no, no" survives.
//
// Ported from guard_repetition_loops in audio_gate.py, step for step.

public enum RepetitionLoopGuard {
    static let maxNgram = 4
    static let alwaysRepeats = 8
    static let fastRepeats = 4
    static let fastWordsPerSec = 6.0

    /// Collapses Whisper's runaway repeats, or drops text that is only a loop.
    ///
    /// Each run of a 1 to 4 word phrase repeated back to back enough times is cut down to a
    /// single copy. If nothing else is left, the clip is treated as a hallucination and ""
    /// is returned, so nothing gets pasted.
    public static func guardLoops(_ text: String, durationSec: Double?) -> String {
        let tokens = PythonText.split(text)
        if tokens.count < fastRepeats { return text }
        // Compared as UTF-8 bytes: Swift's String == treats "é" and "e" plus an accent as
        // equal, Python doesn't.
        let keys = tokens.map { Array(loopKey($0).utf8) }
        // Python's `bool(duration_sec)` is false for both None and 0.
        let tooFast: Bool
        if let durationSec, durationSec != 0 {
            tooFast = Double(tokens.count) / durationSec > fastWordsPerSec
        } else {
            tooFast = false
        }
        let minRepeats = tooFast ? fastRepeats : alwaysRepeats

        var kept: [String] = []
        var looped = false
        var otherWords = 0
        var i = 0
        while i < tokens.count {
            var best: (repeats: Int, n: Int)?
            for n in 1...maxNgram {
                guard i + n <= keys.count else { break }
                let phrase = keys[i..<i + n]
                var repeats = 1
                while i + (repeats + 1) * n <= keys.count,
                      keys[(i + repeats * n)..<(i + (repeats + 1) * n)].elementsEqual(phrase) {
                    repeats += 1
                }
                // Strictly greater, so on a tie the shorter phrase wins, as in Python.
                if repeats >= minRepeats, best == nil || repeats * n > best!.repeats * best!.n {
                    best = (repeats, n)
                }
            }
            guard let (repeats, n) = best else {
                kept.append(tokens[i])
                otherWords += 1
                i += 1
                continue
            }
            looped = true
            kept.append(contentsOf: tokens[i..<i + n])
            i += repeats * n
            // A loop usually stops part way through the phrase ("Call us Call").
            let phrase = Array(keys[(i - n)..<i])
            var tail = 0
            while tail < n - 1, i + tail < keys.count, keys[i + tail] == phrase[tail] {
                tail += 1
            }
            i += tail
        }
        if !looped { return text }
        if otherWords < 2 { return "" }
        return kept.joined(separator: " ")
    }

    /// The token's words in lower case, so "Call," and "call" count as the same word.
    /// Python: `" ".join(re.findall(r"[a-z0-9']+", token.lower())) or token`.
    static func loopKey(_ token: String) -> String {
        var words: [String] = []
        var current = ""
        for scalar in token.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.isEmpty ? token : words.joined(separator: " ")
    }
}
