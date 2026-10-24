import Foundation

/// Whisper's text tokenizer, the way OpenAI's tiktoken (and so mlx-whisper) runs it.
///
/// whisper.cpp's own whisper_tokenize splits each word greedily into the longest tokens it
/// can find, which isn't byte-pair encoding: " Claude" comes out as " Claud" + "e" where
/// tiktoken gives " Cla" + "ude". On the October 2026 word list that changes Claude,
/// Tailscale, Vercel and Parakeet. The prompt tokens decide what Whisper expects to hear,
/// and the benchmarked whisper.cpp runs used tiktoken's, so this repeats tiktoken exactly:
/// the same pre-tokenizer regex, then merging the adjacent pair with the lowest rank until
/// none is left. Whisper's ranks are its token ids, which whisper.cpp's model file has.
public struct WhisperBPETokenizer: Sendable {
    /// Token bytes to rank (which is also the token id) for the ordinary text tokens.
    private let ranks: [[UInt8]: Int32]

    public init(ranks: [[UInt8]: Int32]) {
        self.ranks = ranks
    }

    // tiktoken's GPT-2 pattern, which Whisper uses:
    //   's|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+
    // with \s spelled out as Unicode White_Space, which is what Rust's regex means by it.
    // ICU's \s leaves out vertical tab and U+0085.
    private static let whitespace = #"\t\n\x{0B}\f\r\x{20}\x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}"#
    private static let pattern = "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\(whitespace)\\p{L}\\p{N}]+|[\(whitespace)]+(?![^\(whitespace)])|[\(whitespace)]+"

    /// Ids for `text`. Like tiktoken's encode_ordinary: text that looks like a special token,
    /// such as "<|endoftext|>", is encoded as plain text. (mlx-whisper would refuse it.)
    public func encode(_ text: String) -> [Int32] {
        // The pattern is a constant, so compiling it can't fail.
        let regex = try! NSRegularExpression(pattern: Self.pattern)
        var ids: [Int32] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            ids += encodePiece(Array(text[range].utf8))
        }
        return ids
    }

    func encodePiece(_ piece: [UInt8]) -> [Int32] {
        if let id = ranks[piece] { return [id] }
        // Boundaries between the current parts; start with every byte on its own.
        var bounds = Array(0...piece.count)
        while bounds.count > 2 {
            var best: (rank: Int32, at: Int)?
            for i in 0..<(bounds.count - 2) {
                if let rank = ranks[Array(piece[bounds[i]..<bounds[i + 2]])], best == nil || rank < best!.rank {
                    best = (rank, i)
                }
            }
            guard let best else { break }
            bounds.remove(at: best.at + 1)
        }
        // Every single byte is a token, so each part has a rank.
        return (0..<(bounds.count - 1)).compactMap { ranks[Array(piece[bounds[$0]..<bounds[$0 + 1]])] }
    }
}
