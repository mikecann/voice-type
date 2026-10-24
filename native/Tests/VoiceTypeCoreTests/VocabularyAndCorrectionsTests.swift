import Foundation
import Testing
@testable import VoiceTypeCore

// Ported from VocabularyPromptTests in tests/test_speech_backends.py, plus edge cases of
// build_vocabulary_prompt.
struct VocabularyPromptTests {
    @Test func promptListsWordsAsOnePunctuatedSentence() {
        #expect(VocabularyPrompt.build(["Convex", " Tailscale ", "", "Convex", "Sammy Cam"]) == "Convex, Tailscale, Sammy Cam.")
    }

    @Test func noWordsMeansNoPrompt() {
        #expect(VocabularyPrompt.build([]) == nil)
        #expect(VocabularyPrompt.build(nil) == nil)
        #expect(VocabularyPrompt.build(["  "]) == nil)
    }

    @Test func duplicatesAreFoundByCaseFolding() {
        // The first spelling wins, as in Python, and casefold() folds ß to ss.
        #expect(VocabularyPrompt.build(["convex", "CONVEX", "Straße", "STRASSE"]) == "convex, Straße.")
    }

    @Test func stripsPythonWhitespace() {
        // \u{1F} counts as whitespace for Python's str.strip() but not Foundation's.
        #expect(VocabularyPrompt.build(["\u{1F}Tapo\u{A0}", "\tKokoro\n"]) == "Tapo, Kokoro.")
    }

    @Test func tokenizerInputHasTheLeadingSpaceMlxAdds() {
        #expect(VocabularyPrompt.tokenizerInput(for: "Convex, Tailscale.") == " Convex, Tailscale.")
    }
}

// _apply_corrections has no Python tests; every expected string here is what Python's re.sub
// loop gives for the same input.
struct CorrectionsTests {
    let defaults = Corrections.pythonDefaults

    @Test func defaultsFixCuda() {
        #expect(defaults.apply("I wrote it in q da and Kuda.") == "I wrote it in CUDA and CUDA.")
        #expect(defaults.apply("KUDA, kuda; kUdA!") == "CUDA, CUDA; CUDA!")
        #expect(defaults.apply("Kuda's fine") == "CUDA's fine")
        #expect(defaults.apply("(Kuda)") == "(CUDA)")
        #expect(defaults.apply("Kuda\nKuda") == "CUDA\nCUDA")
    }

    @Test func onlyWholeWordsMatch() {
        #expect(defaults.apply("Kudamon and makuda stay") == "Kudamon and makuda stay")
        // Underscores and accented letters are word characters in Python's \w.
        #expect(defaults.apply("kuda_x and x_kuda stay") == "kuda_x and x_kuda stay")
        #expect(defaults.apply("éKuda and Kudaé stay") == "éKuda and Kudaé stay")
        // The space inside a key is literal.
        #expect(defaults.apply("q  da has two spaces") == "q  da has two spaces")
    }

    @Test func runInOrderSoOneCanFeedTheNext() {
        let corrections = Corrections([("congress", "Convex"), ("convex db", "Convex DB")])
        #expect(corrections.apply("Congress db is great") == "Convex DB is great")
    }

    @Test func keysAreLiteralText() {
        let corrections = Corrections([("C++", "C plus plus"), ("a.b", "AB")])
        #expect(corrections.apply("c++ and axb and a.b") == "C plus plus and axb and AB")
    }

    @Test func dollarSignsInReplacementsAreTyped() {
        #expect(Corrections([("pay", "$1 now")]).apply("pay up") == "$1 now up")
    }

    @Test func settingsOrderIsKept() {
        let json = #"{"corrections": {"Tail scale": "Tailscale", "tailscale": "TailScale"}}"#
        let settings = VoiceTypeSettings.parse(try! OrderedJSONParser.parse(Data(json.utf8)))
        #expect(settings.corrections.pairs.map(\.wrong) == ["Tail scale", "tailscale"])
        #expect(settings.corrections.apply("tail scale TAILSCALE") == "TailScale TailScale")
    }
}
