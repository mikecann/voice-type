import Foundation

/// A moment to the microsecond, which is what Python's datetime holds.
///
/// Recording ids and created_at strings are compared and sorted as text by the benchmark and
/// by the archive's cleanup, so they're built from whole microseconds exactly as Python's
/// strftime and isoformat would print them.
public struct Timestamp: Comparable, Sendable {
    public let microseconds: Int64

    public init(microseconds: Int64) { self.microseconds = microseconds }

    /// Python's datetime.fromtimestamp rounds to the nearest microsecond.
    public init(_ date: Date) {
        self.microseconds = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    public var date: Date { Date(timeIntervalSince1970: Double(microseconds) / 1_000_000) }

    public static func < (a: Timestamp, b: Timestamp) -> Bool { a.microseconds < b.microseconds }

    public func adding(seconds: Double) -> Timestamp {
        Timestamp(microseconds: microseconds + Int64((seconds * 1_000_000).rounded()))
    }

    private struct Fields { var year, month, day, hour, minute, second, micro: Int }

    private func fields(offsetSeconds: Int) -> Fields {
        let shifted = microseconds + Int64(offsetSeconds) * 1_000_000
        let (secs, micro) = floorDivMod(shifted, 1_000_000)
        let (days, secOfDay) = floorDivMod(secs, 86_400)
        let (y, m, d) = civilFromDays(days)
        return Fields(year: y, month: m, day: d, hour: Int(secOfDay / 3600), minute: Int(secOfDay % 3600 / 60),
                      second: Int(secOfDay % 60), micro: Int(micro))
    }

    /// `strftime("%Y%m%dT%H%M%S%fZ")` in UTC, the start of every recording id.
    public var recordingIDPrefix: String {
        let f = fields(offsetSeconds: 0)
        return pad(f.year, 4) + pad(f.month, 2) + pad(f.day, 2) + "T" + pad(f.hour, 2) + pad(f.minute, 2)
            + pad(f.second, 2) + pad(f.micro, 6) + "Z"
    }

    /// `datetime.now(timezone.utc).isoformat()`. Python leaves the fraction out entirely when
    /// the microseconds are zero.
    public var utcISOFormat: String { isoFormat(offsetSeconds: 0, includeMicroseconds: true) }

    /// `datetime.now().astimezone().isoformat(timespec="seconds")`, the history's timestamps.
    public func localISOFormatSeconds(timeZone: TimeZone = .current) -> String {
        isoFormat(offsetSeconds: timeZone.secondsFromGMT(for: date), includeMicroseconds: false)
    }

    func isoFormat(offsetSeconds: Int, includeMicroseconds: Bool) -> String {
        let f = fields(offsetSeconds: offsetSeconds)
        var s = pad(f.year, 4) + "-" + pad(f.month, 2) + "-" + pad(f.day, 2) + "T" + pad(f.hour, 2) + ":"
            + pad(f.minute, 2) + ":" + pad(f.second, 2)
        if includeMicroseconds && f.micro != 0 { s += "." + pad(f.micro, 6) }
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(offsetSeconds)
        s += sign + pad(magnitude / 3600, 2) + ":" + pad(magnitude % 3600 / 60, 2)
        if magnitude % 60 != 0 { s += ":" + pad(magnitude % 60, 2) }
        return s
    }

    /// Parses a recording id's `%Y%m%dT%H%M%S%fZ` prefix (always 6 fraction digits in our ids).
    public static func parseRecordingIDPrefix(_ s: String) -> Timestamp? {
        let digits = Array(s.utf8)
        guard digits.count == 22, digits[8] == UInt8(ascii: "T"), digits[21] == UInt8(ascii: "Z") else { return nil }
        func number(_ range: Range<Int>) -> Int? { Int(String(decoding: digits[range], as: UTF8.self)) }
        guard let y = number(0..<4), let mo = number(4..<6), let d = number(6..<8), let h = number(9..<11),
              let mi = number(11..<13), let se = number(13..<15), let us = number(15..<21) else { return nil }
        return make(year: y, month: mo, day: d, hour: h, minute: mi, second: se, micro: us, offsetSeconds: 0)
    }

    /// Python's datetime.fromisoformat for the forms Voice Type writes: `YYYY-MM-DD`, then `T`
    /// or a space, `HH:MM[:SS[.fff or .ffffff]]`, then an optional `Z` or `±HH:MM[:SS]`.
    /// Anything else gives nil.
    public static func parseISO(_ s: String) -> ParsedISO? {
        let b = Array(s.utf8)
        var i = 0
        func digits(_ n: Int) -> Int? {
            guard i + n <= b.count, b[i..<i + n].allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
            defer { i += n }
            return Int(String(decoding: b[i..<i + n], as: UTF8.self))
        }
        func expect(_ c: Character) -> Bool {
            guard i < b.count, b[i] == c.asciiValue! else { return false }
            i += 1
            return true
        }
        guard let y = digits(4), expect("-"), let mo = digits(2), expect("-"), let d = digits(2) else { return nil }
        var h = 0, mi = 0, se = 0, us = 0
        if i < b.count {
            guard b[i] == UInt8(ascii: "T") || b[i] == UInt8(ascii: " ") else { return nil }
            i += 1
            guard let hh = digits(2), expect(":"), let mm = digits(2) else { return nil }
            h = hh; mi = mm
            if expect(":") {
                guard let ss = digits(2) else { return nil }
                se = ss
                if expect(".") {
                    let start = i
                    while i < b.count, (0x30...0x39).contains(b[i]) { i += 1 }
                    let count = i - start
                    guard count == 3 || count == 6 else { return nil }
                    let frac = Int(String(decoding: b[start..<i], as: UTF8.self))!
                    us = count == 3 ? frac * 1000 : frac
                }
            }
        }
        var offset: Int?
        if i < b.count {
            if expect("Z") {
                offset = 0
            } else if b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") {
                let sign = b[i] == UInt8(ascii: "-") ? -1 : 1
                i += 1
                guard let oh = digits(2), expect(":"), let om = digits(2) else { return nil }
                var os = 0
                if expect(":") { guard let v = digits(2) else { return nil }; os = v }
                offset = sign * (oh * 3600 + om * 60 + os)
            } else {
                return nil
            }
        }
        guard i == b.count, (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 60 else { return nil }
        return ParsedISO(year: y, month: mo, day: d, hour: h, minute: mi, second: se, micro: us, offsetSeconds: offset)
    }

    /// A parsed ISO time. Times without a zone (the ones Python's old log import wrote) only
    /// become a moment once a zone is chosen for them.
    public struct ParsedISO: Sendable {
        let year, month, day, hour, minute, second, micro: Int
        public let offsetSeconds: Int?

        public func timestamp(assumingOffset defaultOffset: Int) -> Timestamp {
            Timestamp.make(year: year, month: month, day: day, hour: hour, minute: minute, second: second,
                           micro: micro, offsetSeconds: offsetSeconds ?? defaultOffset)
        }
    }

    static func make(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, micro: Int, offsetSeconds: Int) -> Timestamp {
        let days = daysFromCivil(year, month, day)
        let secs = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        return Timestamp(microseconds: secs * 1_000_000 + Int64(micro))
    }
}

private func pad(_ value: Int, _ width: Int) -> String {
    let s = String(value)
    return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
}

private func floorDivMod(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
    var q = a / b, r = a % b
    if r < 0 { q -= 1; r += b }
    return (q, r)
}

// Howard Hinnant's days-from-civil, for the proleptic Gregorian calendar Python uses.
private func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int64 {
    let y = Int64(m <= 2 ? y0 - 1 : y0)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = Int64((m + 9) % 12)
    let doy = (153 * mp + 2) / 5 + Int64(d) - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

private func civilFromDays(_ z0: Int64) -> (Int, Int, Int) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
    return (Int(y), Int(m), Int(d))
}
