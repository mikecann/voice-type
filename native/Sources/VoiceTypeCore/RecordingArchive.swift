import Foundation

/// The dictation audio and metadata the Python app keeps for 30 days, ported from
/// recording_archive.py so both apps write the same files.
///
/// Each recording is a mono 32-bit float WAV (format 3 with a fact chunk, so a replay sees
/// exactly what Whisper saw; PCM16 would quantise quiet clips) and a JSON file next to it,
/// both named after the UTC capture time plus a random hex id. Writes are atomic and
/// owner-only. Cleanup goes by the time in the file name, never by mtime, and only ever
/// touches files that match our naming.
public final class RecordingArchive: @unchecked Sendable {
    public let directory: URL
    public let retentionDays: Int
    private let clock: () -> Date
    private let makeHexID: () -> String
    private let lock = NSLock()

    public init(
        directory: URL,
        retentionDays: Int = 30,
        clock: @escaping () -> Date = Date.init,
        makeHexID: @escaping () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    ) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.clock = clock
        self.makeHexID = makeHexID
    }

    /// The float WAV bytes Python's struct.pack calls produce.
    public static func wavData(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let audioBytes = samples.count * 4
        data.append(contentsOf: Array("RIFF".utf8))
        // fmt (8 + 16) + fact (8 + 4) + data (8 + audio), plus the 4 bytes of "WAVE".
        u32(UInt32(24 + 12 + 8 + audioBytes + 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(3)  // IEEE float
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 4))
        u16(4)
        u16(32)
        data.append(contentsOf: Array("fact".utf8))
        u32(4)
        u32(UInt32(samples.count))
        data.append(contentsOf: Array("data".utf8))
        u32(UInt32(audioBytes))
        // '<f4': little-endian float32, which is also the in-memory layout on every Mac.
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Saves a capture with status "captured" and returns its id. `metadata` comes first in
    /// the JSON, then the archive's own fields, as `{**metadata, 'id': ...}` orders them.
    @discardableResult
    public func save(_ samples: [Float], sampleRate: Int, metadata: [(key: String, value: JSONValue)]) throws -> String {
        let now = Timestamp(clock())
        let id = "\(now.recordingIDPrefix)_\(makeHexID())"
        var entry = JSONValue.object(metadata)
        entry.update(with: [
            ("id", .string(id)),
            ("created_at", .string(now.utcISOFormat)),
            ("audio_file", .string("\(id).wav")),
            ("sample_rate", .int(sampleRate)),
            ("sample_count", .int(samples.count)),
            ("duration_seconds", .double(Double(samples.count) / Double(sampleRate))),
            ("status", .string("captured")),
        ])
        let wav = Self.wavData(samples, sampleRate: sampleRate)
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Python chmods on every save, in case the folder was made some other way.
            chmod(directory.path, 0o700)
            try Self.writeAtomic(wav, to: directory.appendingPathComponent("\(id).wav"))
            try writeJSON(id: id, entry)
        }
        return id
    }

    /// Merges fields into a saved recording's JSON. A recording that has already expired is
    /// left gone rather than recreated by a late finaliser.
    public func update(_ id: String, _ fields: [(key: String, value: JSONValue)]) throws {
        try lock.withLock {
            let url = directory.appendingPathComponent("\(id).json")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var entry = try OrderedJSONParser.parse(Data(contentsOf: url))
            entry.update(with: fields)
            try writeJSON(id: id, entry)
        }
    }

    /// Reads a saved recording's JSON, for tests and the status of the last dictation.
    public func entry(_ id: String) -> JSONValue? {
        lock.withLock {
            (try? Data(contentsOf: directory.appendingPathComponent("\(id).json"))).flatMap { try? OrderedJSONParser.parse($0) }
        }
    }

    /// Deletes recordings, and interrupted writes, captured more than `retentionDays` ago.
    @discardableResult
    public func cleanup() -> Int {
        let cutoff = Timestamp(clock()).adding(seconds: -Double(retentionDays) * 86_400)
        return lock.withLock {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
            var removed = 0
            for name in names {
                guard let created = Self.captureTime(ofFileNamed: name), created < cutoff else { continue }
                if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                    removed += 1
                }
            }
            return removed
        }
    }

    /// The capture time in a name like `20261024T023111950600Z_<32 hex>.wav[.tmp]`, or nil
    /// for anything that isn't one of ours.
    static func captureTime(ofFileNamed name: String) -> Timestamp? {
        let parts = name.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rest = parts[1]
        let hex = rest.prefix(32)
        guard hex.count == 32, hex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        let suffix = rest.dropFirst(32)
        guard [".wav", ".json", ".wav.tmp", ".json.tmp"].contains(String(suffix)) else { return nil }
        return Timestamp.parseRecordingIDPrefix(String(parts[0]))
    }

    private func writeJSON(id: String, _ entry: JSONValue) throws {
        // json.dumps(entry, ensure_ascii=False, indent=2) + "\n"
        let text = PythonJSON.dumps(entry, indent: 2, ensureASCII: false) + "\n"
        try Self.writeAtomic(Data(text.utf8), to: directory.appendingPathComponent("\(id).json"))
    }

    /// Writes to `<name>.tmp` with mode 0600, fsyncs, then renames over the target, so a crash
    /// leaves either the old file or the new one and never a torn one.
    static func writeAtomic(_ data: Data, to url: URL) throws {
        let temporary = url.path + ".tmp"
        defer { unlink(temporary) }
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        fchmod(fd, 0o600)
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard written, synced else { throw POSIXError(.EIO) }
        guard rename(temporary, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
