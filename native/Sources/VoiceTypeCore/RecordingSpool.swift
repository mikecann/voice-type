import Foundation

/// Writes a dictation's audio to disk while the key is held, so a crash, a watchdog's restart
/// or a forced restart in the middle of one doesn't lose it (issue #7: a 68 s dictation went
/// that way, since the audio was only saved at key-up).
///
/// The file is `recordings/<id>.wav.partial`: the float WAV header RecordingArchive writes,
/// with its sizes left at zero, then the samples as they arrive. Once the finaliser has saved
/// the recording properly at key-up the partial file is deleted; one still there at launch was
/// interrupted, and DictationRecovery turns it into a recording. Only written when recordings
/// are kept (`audio_recording_enabled`), since it's the same audio.
///
/// Everything happens on the spool's own serial queue, in the order it was asked for, so
/// neither the controller's queue nor the audio drain ever waits on the disk. A crash loses
/// at most the few blocks still queued.
public final class RecordingSpool: @unchecked Sendable {
    /// One key hold's file.
    public final class Session: @unchecked Sendable {
        public let url: URL
        fileprivate var fd: Int32 = -1
        fileprivate var failed = false
        init(url: URL) { self.url = url }
    }

    public static let suffix = ".wav.partial"
    /// RecordingArchive.wavData's header: RIFF (12), fmt (24), fact (12) and data's own 8.
    public static let headerBytes = 56

    public let directory: URL
    private let clock: () -> Date
    private let makeHexID: () -> String
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "voice-type.recording-spool", qos: .utility)
    /// The session blocks go to. Only touched on `queue`.
    private var current: Session?

    public init(directory: URL, clock: @escaping () -> Date = Date.init,
                makeHexID: @escaping () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() },
                log: @escaping @Sendable (String) -> Void) {
        self.directory = directory
        self.clock = clock
        self.makeHexID = makeHexID
        self.log = log
    }

    /// Starts a file for the key hold that's starting. Named after now, like a recording.
    public func begin() -> Session {
        let name = "\(Timestamp(clock()).recordingIDPrefix)_\(makeHexID())\(Self.suffix)"
        let session = Session(url: directory.appendingPathComponent(name))
        let directory = self.directory
        queue.async { [self] in
            close(current)
            current = session
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let fd = open(session.url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                session.fd = fd
                // The header with no samples yet; recovery works the length out from the file.
                let header = [UInt8](RecordingArchive.wavData([], sampleRate: sampleRate))
                guard Self.writeAll(fd, header) else { throw POSIXError(.EIO) }
            } catch {
                fail(session, "Couldn't start writing the dictation to disk: \(error.localizedDescription)")
            }
        }
        return session
    }

    /// A block of 16 kHz samples for the current session, from the audio drain.
    public func append(_ block: [Float]) {
        guard !block.isEmpty else { return }
        queue.async { [self] in
            guard let session = current, session.fd >= 0 else { return }
            let ok = block.withUnsafeBytes { raw in Self.writeAll(session.fd, raw) }
            if !ok { fail(session, "Writing the dictation to disk failed (disk full?); it's still kept in memory.") }
        }
    }

    /// The key went up: nothing more goes to `session`. The file stays until `discard`.
    public func end(_ session: Session) {
        queue.async { [self] in
            if current === session { current = nil }
            close(session)
        }
    }

    /// The recording was saved properly (or the key hold never became one): the partial
    /// file isn't needed.
    public func discard(_ session: Session) {
        queue.async { [self] in
            if current === session { current = nil }
            close(session)
            unlink(session.url.path)
        }
    }

    /// The same, done before returning. The finaliser uses this right after saving the
    /// recording, so there's no moment where a crash would leave both the recording and its
    /// partial file for the next launch to recover twice.
    public func discardNow(_ session: Session) {
        queue.sync {
            if current === session { current = nil }
            close(session)
            unlink(session.url.path)
        }
    }

    /// Waits for everything asked for so far, for tests.
    public func flush() { queue.sync {} }

    private func close(_ session: Session?) {
        guard let session, session.fd >= 0 else { return }
        Darwin.close(session.fd)
        session.fd = -1
    }

    private func fail(_ session: Session, _ message: String) {
        close(session)
        if !session.failed {
            session.failed = true
            log(message)
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { writeAll(fd, $0) }
    }

    private static func writeAll(_ fd: Int32, _ raw: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    // MARK: Reading them back

    /// Partial files left in `directory`, oldest first.
    public static func leftovers(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) && RecordingArchive.captureTime(ofFileNamed: $0) != nil }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    /// When a partial file's key hold started, from its name.
    public static func capturedAt(_ url: URL) -> Date? {
        RecordingArchive.captureTime(ofFileNamed: url.lastPathComponent)?.date
    }

    /// A partial file's samples: whatever whole floats follow the header.
    public static func samples(in url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > headerBytes else { return [] }
        let count = (data.count - headerBytes) / 4
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { out in
            data.copyBytes(to: out, from: headerBytes..<(headerBytes + count * 4))
        }
        return samples
    }
}
