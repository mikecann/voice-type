import Foundation

// "[n]" markers in the dictated text, ported from screen_marks.py.
//
// Markers go in after corrections, never through them. The timed words from Whisper are
// aligned to the final text word by word, which survives corrections, casing and punctuation
// changes, so a marker lands after the word being spoken when the mark was finished.

/// A word or segment from the speech model, timed in seconds of audio.
public struct TimedText: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(_ start: Double, _ end: Double, _ text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum MarkMarkers {
    static let trailingPunctuation: Set<Unicode.Scalar> = Set(".,!?;:)]}\"'\u{201D}\u{2019}\u{2026}".unicodeScalars)

    /// Python's `re.sub(r"[^\w]", "", token.casefold())`: lower case, letters, digits and
    /// underscores only.
    static func normalize(_ token: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in token.lowercased().unicodeScalars where isWordCharacter(scalar) { out.append(scalar) }
        return String(out)
    }

    /// Python's `\w` for str patterns: str.isalnum() or an underscore.
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return scalar.properties.numericType != nil
        }
    }

    static func words(_ text: String) -> [String] {
        PythonText.split(text).map(normalize).filter { !$0.isEmpty }
    }

    /// Word and segment timings from a transcript. Segments without timings (or text) give
    /// nothing, and words only come when they were asked for.
    public static func timings(from transcript: Transcript?) -> (words: [TimedText], segments: [TimedText]) {
        var words: [TimedText] = []
        var segments: [TimedText] = []
        for segment in transcript?.segments ?? [] {
            let text = PythonText.strip(segment.text)
            if !text.isEmpty && segment.endSec > 0 { segments.append(TimedText(segment.startSec, segment.endSec, text)) }
            for word in segment.words where !PythonText.strip(word.text).isEmpty { words.append(word) }
        }
        return (words, segments)
    }

    /// For each mark, how many transcribed words came before it. With word timings, a mark
    /// goes after the word being spoken when it was finished. With only segment timings, it
    /// goes at the nearest segment boundary. Nil when there's no timing at all.
    public static func spokenWordCounts(_ markTimes: [Double], words: [TimedText], segments: [TimedText]) -> [Int]? {
        if !words.isEmpty {
            return markTimes.map { t in
                words.filter { $0.start <= t }.reduce(0) { $0 + Self.words($1.text).count }
            }
        }
        if let first = segments.first {
            var boundaries = [(first.start, 0)]
            var total = 0
            for segment in segments {
                total += Self.words(segment.text).count
                boundaries.append((segment.end, total))
            }
            return markTimes.map { t in
                // min() over (distance, -count): the nearest boundary, the later one on a tie.
                boundaries.min { a, b in
                    let da = abs(a.0 - t), db = abs(b.0 - t)
                    return da != db ? da < db : -a.1 < -b.1
                }!.1
            }
        }
        return nil
    }

    public static func markerText(_ numbers: [Int]) -> String { numbers.map { "[\($0)]" }.joined(separator: " ") }

    public static func appendMarkers(_ text: String, _ numbers: [Int]) -> String {
        guard !numbers.isEmpty else { return text }
        if PythonText.strip(text).isEmpty { return markerText(numbers) }
        return "\(rstrip(text)) \(markerText(numbers))"
    }

    static func rstrip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let last = scalars.lastIndex(where: { !PythonText.isSpace($0) }) else { return "" }
        return String(scalars[...last])
    }

    /// Puts "[n]" markers into `finalText` after the counted spoken words. `spokenText` is
    /// what the timings describe (Whisper's raw text). Its words are aligned to `finalText`,
    /// so corrections don't throw the markers off. Without counts, markers go on the end.
    public static func insertMarkers(_ finalText: String, spoken spokenText: String, wordCounts: [Int]?, numbers: [Int]) -> String {
        guard !numbers.isEmpty else { return finalText }
        guard let wordCounts, !PythonText.strip(finalText).isEmpty else { return appendMarkers(finalText, numbers) }

        // Python indexes strings by code point, so the spans do too.
        let text = Array(finalText.unicodeScalars)
        let spoken = words(spokenText)
        let finalTokens = tokenSpans(text).filter { !$0.word.isEmpty }
        // Spoken word index -> final token index, carrying the last match forward over words
        // that corrections replaced.
        var matches: [Int: Int] = [:]
        for block in SequenceMatcher(spoken, finalTokens.map(\.word)).matchingBlocks() {
            for i in 0..<block.size { matches[block.a + i] = block.b + i }
        }
        var mapped: [Int] = []
        var last = -1
        for i in spoken.indices {
            last = matches[i] ?? last
            mapped.append(last)
        }

        var groups: [Int: [Int]] = [:]
        for (count, number) in zip(wordCounts, numbers) {
            let token: Int
            if count <= 0 {
                token = -1
            } else if count >= spoken.count {
                token = finalTokens.count - 1
            } else {
                token = mapped[count - 1]
            }
            groups[token, default: []].append(number)
        }

        var pieces = String.UnicodeScalarView()
        var cursor = 0
        func append(_ s: String) { pieces.append(contentsOf: s.unicodeScalars) }
        for token in groups.keys.sorted() {
            let label = markerText(groups[token]!)
            if token < 0 {
                append("\(label) ")
                continue
            }
            var offset = insertionOffset(text, end: finalTokens[token].end)
            if offset <= finalTokens[token].start { offset = finalTokens[token].end }
            pieces.append(contentsOf: text[cursor..<offset])
            append(" \(label)")
            cursor = offset
        }
        pieces.append(contentsOf: text[cursor...])
        return String(pieces)
    }

    /// `\S+` runs, with their normalized words.
    static func tokenSpans(_ text: [Unicode.Scalar]) -> [(start: Int, end: Int, word: String)] {
        var spans: [(Int, Int, String)] = []
        var i = 0
        while i < text.count {
            if PythonText.isSpace(text[i]) {
                i += 1
                continue
            }
            let start = i
            while i < text.count && !PythonText.isSpace(text[i]) { i += 1 }
            var token = String.UnicodeScalarView()
            token.append(contentsOf: text[start..<i])
            spans.append((start, i, normalize(String(token))))
        }
        return spans
    }

    /// Steps back over closing punctuation, so "button." becomes "button [1].".
    static func insertionOffset(_ text: [Unicode.Scalar], end: Int) -> Int {
        var end = end
        while end > 0 && trailingPunctuation.contains(text[end - 1]) { end -= 1 }
        return end
    }
}

/// difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks(), which is how
/// Python aligned the spoken words with the final text. No junk, so only the plain longest
/// matching block search and its recursion are needed.
struct SequenceMatcher {
    struct Match: Equatable { var a: Int, b: Int, size: Int }

    let a: [String]
    let b: [String]
    private var b2j: [String: [Int]] = [:]

    init(_ a: [String], _ b: [String]) {
        self.a = a
        self.b = b
        for (j, element) in b.enumerated() { b2j[element, default: []].append(j) }
    }

    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> Match {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        for i in alo..<max(alo, ahi) {
            var newj2len: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                newj2len[j] = k
                if k > bestsize {
                    besti = i - k + 1
                    bestj = j - k + 1
                    bestsize = k
                }
            }
            j2len = newj2len
        }
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            besti -= 1
            bestj -= 1
            bestsize += 1
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return Match(a: besti, b: bestj, size: bestsize)
    }

    func matchingBlocks() -> [Match] {
        var queue = [(0, a.count, 0, b.count)]
        var blocks: [Match] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let x = findLongestMatch(alo, ahi, blo, bhi)
            guard x.size > 0 else { continue }
            blocks.append(x)
            if alo < x.a && blo < x.b { queue.append((alo, x.a, blo, x.b)) }
            if x.a + x.size < ahi && x.b + x.size < bhi { queue.append((x.a + x.size, ahi, x.b + x.size, bhi)) }
        }
        blocks.sort { ($0.a, $0.b, $0.size) < ($1.a, $1.b, $1.size) }
        var collapsed: [Match] = []
        var i1 = 0, j1 = 0, k1 = 0
        for block in blocks {
            if i1 + k1 == block.a && j1 + k1 == block.b {
                k1 += block.size
            } else {
                if k1 > 0 { collapsed.append(Match(a: i1, b: j1, size: k1)) }
                (i1, j1, k1) = (block.a, block.b, block.size)
            }
        }
        if k1 > 0 { collapsed.append(Match(a: i1, b: j1, size: k1)) }
        collapsed.append(Match(a: a.count, b: b.count, size: 0))
        return collapsed
    }
}
