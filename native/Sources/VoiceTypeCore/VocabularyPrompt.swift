import Foundation

public enum VocabularyPrompt {
    /// Turns the vocabulary setting into Whisper's initial prompt, as build_vocabulary_prompt
    /// in speech_backends.py does.
    ///
    /// A backtest on Mike's own recordings found a prompt like "Convex, Tailscale, Sammy Cam."
    /// fixed most misheard names and kept capitals and punctuation on short dictations, where
    /// Whisper otherwise drops them about a third of the time.
    public static func build(_ words: [String]?) -> String? {
        // Duplicates are dropped by Python's str.casefold(). Foundation's case-insensitive
        // folding is the same full folding ("Straße" and "STRASSE" match), and the folded
        // forms are compared as bytes, as a Python set does.
        var seen: Set<[UInt8]> = []
        var cleaned: [String] = []
        for word in words ?? [] {
            let word = PythonText.strip(word)
            guard !word.isEmpty else { continue }
            let folded = Array(word.folding(options: [.caseInsensitive], locale: nil).utf8)
            if seen.insert(folded).inserted {
                cleaned.append(word)
            }
        }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ") + "."
    }

    /// The text Whisper's tokenizer encodes for a prompt.
    ///
    /// mlx_whisper.transcribe encodes `" " + initial_prompt.strip()`, and the benchmarked
    /// whisper.cpp runs took their prompt tokens from that, so the leading space is part of
    /// matching them. whisper.cpp's own `initial_prompt` would tokenize the prompt without it.
    public static func tokenizerInput(for prompt: String) -> String {
        " " + PythonText.strip(prompt)
    }
}
