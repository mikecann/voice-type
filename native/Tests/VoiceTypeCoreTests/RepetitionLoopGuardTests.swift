import Testing
@testable import VoiceTypeCore

// Ported from RepetitionLoopGuardTests in tests/test_audio_gate.py.
struct RepetitionLoopGuardTests {
    func guardLoops(_ text: String, _ durationSec: Double?) -> String {
        RepetitionLoopGuard.guardLoops(text, durationSec: durationSec)
    }

    @Test func dropsAClipThatIsOnlyALoop() {
        // Both of these were pasted for real in October 2026.
        #expect(guardLoops(Array(repeating: "making", count: 300).joined(separator: " "), 1.4) == "")
        #expect(guardLoops(String(repeating: "Call us ", count: 100) + "Call", 0.4) == "")
        #expect(guardLoops("Flare. Flare. Flare. Flare. Flare. Flare. Flare. Flare.", 2.0) == "")
    }

    @Test func collapsesALoopAfterRealWords() {
        let text = "I think we should ship it today. " + String(repeating: "the ", count: 40)
        #expect(guardLoops(PythonText.strip(text), 6.0) == "I think we should ship it today. the")
    }

    @Test func keepsAFewRepeatsAtANormalPace() {
        #expect(guardLoops("No, no, no, no.", 1.5) == "No, no, no, no.")
        #expect(guardLoops("Okay, okay, okay, okay, let's go.", 2.5) == "Okay, okay, okay, okay, let's go.")
    }

    @Test func fourRepeatsCountWhenTheyCameOutTooFast() {
        #expect(guardLoops("Call us Call us Call us Call us", 0.5) == "")
    }

    @Test func leavesOrdinaryTextAlone() {
        for text in ["", "Merge it.", "Can you take a look at the PR, please?"] {
            #expect(guardLoops(text, 2.0) == text)
        }
    }

    // Edge cases of the Python code, checked against guard_repetition_loops by hand.

    @Test func noDurationMeansOnlyTheEightRepeatRule() {
        #expect(guardLoops("Call us Call us Call us Call us", nil) == "Call us Call us Call us Call us")
        #expect(guardLoops("Call us Call us Call us Call us", 0) == "Call us Call us Call us Call us")
    }

    @Test func untouchedTextKeepsItsSpacing() {
        // Only a collapsed loop is re-joined with single spaces.
        #expect(guardLoops("  one   two  three four  ", 2.0) == "  one   two  three four  ")
        #expect(guardLoops("Ship  it now: " + String(repeating: "go ", count: 9), 9.0) == "Ship it now: go")
    }

    @Test func shorterPhraseWinsATie() {
        // "a a a a a a a a" is 8 one-word repeats and 4 two-word ones; both cover 8 words.
        #expect(guardLoops("so then " + String(repeating: "a ", count: 8), 10.0) == "so then a")
    }

    @Test func dropsThePartialPhraseAtTheEnd() {
        #expect(guardLoops("Fine by me. " + String(repeating: "Call us ", count: 8) + "Call", 10.0) == "Fine by me. Call us")
    }

    @Test func punctuationAndCaseDoNotHideALoop() {
        #expect(guardLoops("Well okay. " + String(repeating: "Yes, YES! ", count: 4), 1.0) == "Well okay. Yes,")
    }

    @Test func tokensWithoutWordsCompareAsThemselves() {
        #expect(guardLoops("so it goes " + String(repeating: "… ", count: 8), 10.0) == "so it goes …")
        // Python compares code points, so a precomposed é and e plus an accent differ.
        let mixed = (0..<8).map { $0 % 2 == 0 ? "é" : "e\u{301}" }.joined(separator: " ")
        #expect(guardLoops("so it goes " + mixed, 10.0) == "so it goes " + mixed)
    }
}
