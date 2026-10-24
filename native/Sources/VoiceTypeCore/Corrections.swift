import Foundation

/// User-defined word and phrase corrections from settings.json, applied after every
/// transcription. Ported from _apply_corrections in voice-type.py.
///
/// Keys are what the model says, matched case-insensitively as whole words; values are typed
/// with their exact casing. They run one after another in the order settings.json lists
/// them, so an earlier correction's output can be matched by a later one.
public struct Corrections {
    public let pairs: [(wrong: String, right: String)]
    private let patterns: [NSRegularExpression]

    public init(_ pairs: [(wrong: String, right: String)]) {
        self.pairs = pairs
        // Python builds `(?<!\w)` + re.escape(wrong) + `(?!\w)`. ICU's \w also counts
        // combining marks and joiners as word characters, and Python's counts every letter
        // and number, so the class is spelled out to mean what Python's \w means.
        let word = #"[\p{L}\p{N}_]"#
        self.patterns = pairs.map { pair in
            let pattern = "(?<!\(word))" + NSRegularExpression.escapedPattern(for: pair.wrong) + "(?!\(word))"
            // escapedPattern always produces a valid pattern, so this can't fail.
            return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    /// The defaults voice-type.py writes when settings.json has no corrections.
    public static var pythonDefaults: Corrections { Corrections([("Q DA", "CUDA"), ("Kuda", "CUDA")]) }

    public func apply(_ text: String) -> String {
        var text = text
        for (pattern, pair) in zip(patterns, pairs) {
            // Python's re.sub would read backslash escapes in the replacement (and fail on
            // ones it doesn't know). Real corrections are plain words, so it's typed as is.
            text = pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: pair.right)
            )
        }
        return text
    }
}
