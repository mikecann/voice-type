import Foundation
import Testing
@testable import VoiceTypeCore

/// The fixture holds mlx-whisper's token ids for a few texts, including the October 2026 word
/// list prompt, and just the part of tiktoken's rank table those texts can reach (every
/// byte substring of every pre-tokenized piece), which is all byte-pair encoding looks at.
struct TokenizerFixture: Decodable {
    struct Case: Decodable {
        let text: String
        let ids: [Int32]
    }
    let ranks: [String: Int32]
    let cases: [Case]

    static func load() throws -> TokenizerFixture {
        let url = try #require(Bundle.module.url(forResource: "tiktoken-cases", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(TokenizerFixture.self, from: Data(contentsOf: url))
    }

    var tokenizer: WhisperBPETokenizer {
        var table: [[UInt8]: Int32] = [:]
        for (base64, rank) in ranks { table[Array(Data(base64Encoded: base64)!)] = rank }
        return WhisperBPETokenizer(ranks: table)
    }
}

struct WhisperBPETokenizerTests {
    @Test func matchesMlxWhisperOnTheWordListPrompt() throws {
        let fixture = try TokenizerFixture.load()
        let prompt = VocabularyPrompt.build(VoiceTypeSettings.defaultVocabulary)!
        let first = try #require(fixture.cases.first)
        #expect(first.text == VocabularyPrompt.tokenizerInput(for: prompt))
        #expect(first.ids.count == 55)
        #expect(fixture.tokenizer.encode(first.text) == first.ids)
    }

    @Test func matchesMlxWhisperOnOtherText() throws {
        // Contractions, numbers, accents, CJK, an emoji with a variation selector, runs of
        // spaces and a trailing newline, which exercise each branch of the pattern.
        let fixture = try TokenizerFixture.load()
        let tokenizer = fixture.tokenizer
        for c in fixture.cases.dropFirst() {
            #expect(tokenizer.encode(c.text) == c.ids, "\(c.text.debugDescription)")
        }
    }

    @Test func mergesTheLowestRankFirst() {
        // "abc": ab (rank 5) merges before bc (rank 6), and abc isn't a token.
        let t = WhisperBPETokenizer(ranks: [[97]: 0, [98]: 1, [99]: 2, [97, 98]: 5, [98, 99]: 6])
        #expect(t.encodePiece(Array("abc".utf8)) == [5, 2])
        // Lowest rank wins wherever it is.
        let u = WhisperBPETokenizer(ranks: [[97]: 0, [98]: 1, [99]: 2, [97, 98]: 7, [98, 99]: 6])
        #expect(u.encodePiece(Array("abc".utf8)) == [0, 6])
        // A whole piece that is a token is used directly.
        let v = WhisperBPETokenizer(ranks: [[97]: 0, [98]: 1, [99]: 2, [97, 98, 99]: 9])
        #expect(v.encodePiece(Array("abc".utf8)) == [9])
    }
}
