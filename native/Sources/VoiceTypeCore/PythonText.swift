// Small pieces of Python's str behaviour that the ported logic leans on.
//
// The Python version stripped and split text with str.strip() and str.split(), which treat a
// slightly different set of characters as whitespace than Foundation does (the ASCII
// separators 0x1C to 0x1F count, for one). Using the same set keeps word counts in the loop
// guard and the cleaned word list identical.

public enum PythonText {
    /// The characters for which Python's str.isspace() is true.
    public static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// str.strip() with no arguments.
    public static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// str.split() with no arguments: runs of whitespace separate words, none are empty.
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isSpace(scalar) {
                if !current.isEmpty {
                    words.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }
}
