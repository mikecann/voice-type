import Foundation

/// Writes JSON the way Python's json module does, byte for byte.
///
/// The recordings, the history and settings.json are shared with the Python app, and the
/// benchmark diffs them, so native has to write the same bytes Python would: the same
/// indentation and separators, the same string escapes, and floats in Python's repr form.
public enum PythonJSON {
    /// `json.dumps(value, ensure_ascii=..., indent=indent)`. With no indent this is the compact
    /// default, which still puts a space after "," and ":".
    public static func dumps(_ value: JSONValue, indent: Int? = nil, ensureASCII: Bool = true) -> String {
        var out = ""
        write(value, to: &out, indent: indent, level: 0, ensureASCII: ensureASCII)
        return out
    }

    private static func write(_ value: JSONValue, to out: inout String, indent: Int?, level: Int, ensureASCII: Bool) {
        switch value {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(literal): out += literal
        case let .string(s): writeString(s, to: &out, ensureASCII: ensureASCII)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += indent == nil ? ", " : "," }
                newline(&out, indent: indent, level: level + 1)
                write(item, to: &out, indent: indent, level: level + 1, ensureASCII: ensureASCII)
            }
            newline(&out, indent: indent, level: level)
            out += "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += indent == nil ? ", " : "," }
                newline(&out, indent: indent, level: level + 1)
                writeString(pair.key, to: &out, ensureASCII: ensureASCII)
                out += ": "
                write(pair.value, to: &out, indent: indent, level: level + 1, ensureASCII: ensureASCII)
            }
            newline(&out, indent: indent, level: level)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, indent: Int?, level: Int) {
        guard let indent else { return }
        out += "\n" + String(repeating: " ", count: indent * level)
    }

    /// Python's encoder escapes `"`, `\` and control characters below 0x20, using the short
    /// forms where JSON has one and lower-case `\u00xx` otherwise. With ensure_ascii it also
    /// escapes everything past 0x7F, as UTF-16 surrogate pairs above the BMP. DEL (0x7F) is
    /// left alone in both modes.
    private static func writeString(_ s: String, to out: inout String, ensureASCII: Bool) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += hexEscape(scalar.value)
                } else if ensureASCII && scalar.value > 0x7F {
                    for unit in String(scalar).utf16 { out += hexEscape(UInt32(unit)) }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    private static func hexEscape(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}

public extension JSONValue {
    /// A float as Python's repr writes it. Swift's shortest round-trip description is the same
    /// algorithm and switches to exponents at the same places (1e-05, 1e+16), which a test checks.
    static func double(_ value: Double) -> JSONValue {
        if value.isNaN { return .number("NaN") }
        if value.isInfinite { return .number(value < 0 ? "-Infinity" : "Infinity") }
        return .number(value.description)
    }

    static func int(_ value: Int) -> JSONValue { .number(String(value)) }

    static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    /// Sets a key the way assigning into a Python dict does: an existing key keeps its place,
    /// a new one goes on the end. Does nothing to values that aren't objects.
    mutating func set(_ key: String, _ value: JSONValue) {
        guard case var .object(pairs) = self else { return }
        if let index = pairs.firstIndex(where: { $0.key == key }) {
            pairs[index].value = value
        } else {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }

    /// `dict.update(other)`: each of other's keys in order, as `set` does.
    mutating func update(with other: [(key: String, value: JSONValue)]) {
        for pair in other { set(pair.key, pair.value) }
    }

    var objectPairs: [(key: String, value: JSONValue)]? {
        if case let .object(pairs) = self { return pairs }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    /// Python's truthiness, for settings like `bool(_settings.get("audio_recording_enabled"))`.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case let .bool(b): return b
        case let .number(literal): return Double(literal).map { $0 != 0 } ?? true
        case let .string(s): return !s.isEmpty
        case let .array(items): return !items.isEmpty
        case let .object(pairs): return !pairs.isEmpty
        }
    }
}
