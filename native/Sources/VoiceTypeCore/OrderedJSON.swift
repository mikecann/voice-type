import Foundation

/// A parsed JSON value that keeps object keys in file order.
///
/// Foundation's JSONSerialization hands back an unordered dictionary, but corrections apply
/// in the order settings.json lists them (as they did in the Python version), and one
/// correction can feed the next. Keeping the order is the only way to type the same text.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The literal as written, so integers keep every digit, as Python's json module does.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first(where: { $0.key == key })?.value
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    /// What Python's str() gives for the value json.load would have produced.
    ///
    /// Only used for odd entries in the word list, where Python calls str() on each item.
    /// Floats use Swift's shortest round-trip form, which matches Python's repr apart from
    /// where very large or small numbers switch to an exponent.
    var pythonString: String {
        switch self {
        case .null: return "None"
        case let .bool(b): return b ? "True" : "False"
        case let .number(literal):
            if literal.allSatisfy({ $0.isNumber || $0 == "-" }) {
                // An int: Python drops a leading minus on zero and keeps every digit.
                let negative = literal.hasPrefix("-")
                var digits = negative ? String(literal.dropFirst()) : literal
                while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst() }
                return negative && digits != "0" ? "-" + digits : digits
            }
            switch literal {
            case "NaN": return "nan"
            case "Infinity": return "inf"
            case "-Infinity": return "-inf"
            default: return Double(literal).map { "\($0)" } ?? literal
            }
        case let .string(s): return s
        case .array, .object:
            // Python would print a repr here. Nobody puts a list inside the word list.
            return ""
        }
    }
}

public enum JSONParseError: Error, Equatable {
    case invalid(offset: Int)
}

/// A strict JSON parser in the spirit of Python's json.loads: it also accepts NaN and
/// Infinity, and a repeated key keeps its first position but takes its last value, which
/// is what a Python dict does.
public struct OrderedJSONParser {
    private let bytes: [UInt8]
    private var i = 0

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = OrderedJSONParser(bytes: Array(data))
        // A byte order mark fails here, as it does in Python's json.load.
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.i == parser.bytes.count else { throw JSONParseError.invalid(offset: parser.i) }
        return value
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private mutating func skipWhitespace() {
        while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
    }

    private func fail() -> JSONParseError { .invalid(offset: i) }

    private mutating func consume(_ literal: String) -> Bool {
        let lit = Array(literal.utf8)
        guard i + lit.count <= bytes.count, Array(bytes[i..<i + lit.count]) == lit else { return false }
        i += lit.count
        return true
    }

    private mutating func parseValue() throws -> JSONValue {
        guard i < bytes.count else { throw fail() }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): if consume("true") { return .bool(true) }
        case UInt8(ascii: "f"): if consume("false") { return .bool(false) }
        case UInt8(ascii: "n"): if consume("null") { return .null }
        case UInt8(ascii: "N"): if consume("NaN") { return .number("NaN") }
        case UInt8(ascii: "I"): if consume("Infinity") { return .number("Infinity") }
        default:
            if consume("-Infinity") { return .number("-Infinity") }
            return try parseNumber()
        }
        throw fail()
    }

    private mutating func parseObject() throws -> JSONValue {
        i += 1
        var pairs: [(key: String, value: JSONValue)] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail() }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail() }
            i += 1
            skipWhitespace()
            let value = try parseValue()
            if let existing = pairs.firstIndex(where: { $0.key == key }) {
                pairs[existing].value = value
            } else {
                pairs.append((key, value))
            }
            skipWhitespace()
            guard i < bytes.count else { throw fail() }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            throw fail()
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        i += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw fail() }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw fail()
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        func digits() -> Int {
            let from = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            return i - from
        }
        let intStart = i
        let intDigits = digits()
        // JSON allows no leading zeros, and neither does Python.
        guard intDigits > 0, !(intDigits > 1 && bytes[intStart] == UInt8(ascii: "0")) else { throw fail() }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw fail() }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw fail() }
        }
        return .number(String(decoding: bytes[start..<i], as: UTF8.self))
    }

    private mutating func parseString() throws -> String {
        i += 1
        var scalars = String.UnicodeScalarView()
        var run: [UInt8] = []
        func flush() throws {
            guard !run.isEmpty else { return }
            guard let s = String(validating: run, as: UTF8.self) else { throw fail() }
            scalars.append(contentsOf: s.unicodeScalars)
            run.removeAll()
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                i += 1
                try flush()
                return String(scalars)
            }
            if b < 0x20 { throw fail() }  // Python's strict mode rejects raw control characters.
            if b != UInt8(ascii: "\\") {
                run.append(b)
                i += 1
                continue
            }
            try flush()
            i += 1
            guard i < bytes.count else { throw fail() }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): scalars.append("\"")
            case UInt8(ascii: "\\"): scalars.append("\\")
            case UInt8(ascii: "/"): scalars.append("/")
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800...0xDBFF).contains(code), i + 1 < bytes.count,
                   bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                    let save = i
                    i += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = save
                    }
                }
                // A lone surrogate is legal in Python but can't live in a Swift String.
                scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
            default:
                throw fail()
            }
        }
        throw fail()
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count,
              bytes[i..<i + 4].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
              let value = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw fail() }
        i += 4
        return value
    }
}
