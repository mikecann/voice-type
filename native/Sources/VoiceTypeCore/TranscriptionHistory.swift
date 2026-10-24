import Foundation

/// The completed-dictation history, `transcription-history.jsonl`, ported from
/// transcription_history.py so native appends to the same file in the same format.
///
/// One JSON object per line, keys created_at, mode and text. Each dictation is appended and
/// fsynced as soon as it finishes; the file is only rewritten (atomically) when entries
/// expire, pass the 500 limit, or a line turns out to be corrupt. Python's one-off import of
/// "Done" lines from its old log isn't ported, since native's log never had them.
public final class TranscriptionHistory: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var createdAt: String
        public var mode: String
        public var text: String

        public init(createdAt: String, mode: String, text: String) {
            self.createdAt = createdAt
            self.mode = mode
            self.text = text
        }

        var json: JSONValue {
            .object([("created_at", .string(createdAt)), ("mode", .string(mode)), ("text", .string(text))])
        }

        /// The live writer adds a UTC offset and old log imports didn't, so the first 19
        /// characters (the local second) are what identify a duplicate.
        var key: [String] { [String(createdAt.unicodeScalars.prefix(19)), mode, text] }
    }

    public let url: URL
    public let maxEntries: Int
    public let retentionDays: Int
    private let clock: () -> Date
    private let timeZone: TimeZone
    private let lock = NSLock()

    public init(url: URL, maxEntries: Int = 500, retentionDays: Int = 30, clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.url = url
        self.maxEntries = maxEntries
        self.retentionDays = retentionDays
        self.clock = clock
        self.timeZone = timeZone
    }

    /// Adds a completed dictation. Returns false for blank text, an expired timestamp or a
    /// duplicate, as Python does.
    @discardableResult
    public func append(_ text: String, mode: String, createdAt: String? = nil) throws -> Bool {
        let cleaned = PythonText.strip(text)
        guard !cleaned.isEmpty else { return false }
        let entry = Entry(
            createdAt: createdAt ?? Timestamp(clock()).localISOFormatSeconds(timeZone: timeZone),
            mode: mode,
            text: cleaned
        )
        guard isRetained(entry) else { return false }
        return try lock.withLock {
            var entries = try loadOldestFirst()
            guard !entries.contains(where: { $0.key == entry.key }) else { return false }
            entries.append(entry)
            if entries.count > maxEntries {
                try writeAtomic(Array(entries.suffix(maxEntries)))
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let line = PythonJSON.dumps(entry.json, ensureASCII: false) + "\n"
                let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(fd) }
                let bytes = Array(line.utf8)
                guard write(fd, bytes, bytes.count) == bytes.count, fsync(fd) == 0 else { throw POSIXError(.EIO) }
            }
            return true
        }
    }

    /// Newest first.
    public func load() throws -> [Entry] {
        try lock.withLock {
            // sorted(key=created_at, reverse=True) is stable, so equal times keep file order.
            try loadOldestFirst().enumerated()
                .sorted { a, b in
                    let x = Array(a.element.createdAt.unicodeScalars.map(\.value))
                    let y = Array(b.element.createdAt.unicodeScalars.map(\.value))
                    return x == y ? a.offset < b.offset : x.lexicographicallyPrecedes(y) == false
                }
                .map(\.element)
        }
    }

    private func loadOldestFirst() throws -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        // errors="replace", then splitlines(). The file only ever holds \n line ends; the
        // other separators splitlines() knows would be escaped inside JSON strings anyway.
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        if lines.last == "" { lines.removeLast() }

        var entries: [Entry] = []
        var known = Set<[String]>()
        var needsCompaction = false
        for rawLine in lines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard let item = try? OrderedJSONParser.parse(Data(line.utf8)), case .object = item,
                  let createdAt = item["created_at"]?.stringValue, let mode = item["mode"]?.stringValue,
                  let text = item["text"]?.stringValue else {
                needsCompaction = true
                continue
            }
            guard !PythonText.strip(text).isEmpty else { needsCompaction = true; continue }
            let entry = Entry(createdAt: createdAt, mode: mode, text: text)
            guard isRetained(entry) else { needsCompaction = true; continue }
            if known.insert(entry.key).inserted {
                entries.append(entry)
            } else {
                needsCompaction = true
            }
        }
        let retained = Array(entries.suffix(maxEntries))
        if retained.count != entries.count { needsCompaction = true }
        if needsCompaction { try writeAtomic(retained) }
        return retained
    }

    /// Whether an entry is inside the retention window. Python drops a timestamp it can't
    /// parse; this keeps it instead, so a gap in this parser can never delete someone's history.
    private func isRetained(_ entry: Entry) -> Bool {
        guard let parsed = Timestamp.parseISO(entry.createdAt) else { return true }
        let now = Timestamp(clock())
        // A time without a zone came from the old log, in the machine's local time.
        let created = parsed.timestamp(assumingOffset: timeZone.secondsFromGMT(for: now.date))
        return created >= now.adding(seconds: -Double(retentionDays) * 86_400)
    }

    private func writeAtomic(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = entries.map { PythonJSON.dumps($0.json, ensureASCII: false) + "\n" }.joined()
        // Python writes "<file>.tmp" and os.replace()s it, with the default file mode.
        let temporary = url.path + ".tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array(text.utf8)
        let ok = write(fd, bytes, bytes.count) == bytes.count && fsync(fd) == 0
        close(fd)
        guard ok, rename(temporary, url.path) == 0 else {
            unlink(temporary)
            throw POSIXError(.EIO)
        }
    }
}
