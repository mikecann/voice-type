import Foundation

/// Where the capture worker saves screenshots, and replaces one with a newer composite.
public protocol ScreenshotStoring: AnyObject, Sendable {
    func save(_ png: Data, number: Int) throws -> String
    @discardableResult func discard(_ path: String) -> Bool
}

/// Annotated mark screenshots in `screenshots/`, deleted after a week. Ported from
/// ScreenshotStore in screen_marks.py, with the same file names, so either app cleans up the
/// other's. Like the recording archive, the capture time is in the name, so cleanup doesn't
/// trust mutable mtimes, and files it didn't write are never touched.
public final class ScreenshotStore: ScreenshotStoring, @unchecked Sendable {
    public let directory: URL
    public let retentionDays: Int
    private let now: () -> Date
    private let lock = NSLock()

    public init(directory: URL, retentionDays: Int = ScreenMarks.screenshotRetentionDays, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.retentionDays = retentionDays
        self.now = now
    }

    /// `20261023T005624228899Z_<32 hex>_<n>.png`, or `.png.tmp` while it's being written.
    static func parse(_ name: String) -> Timestamp? {
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 22, parts[1].count == 32,
              parts[1].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        let rest = parts[2]
        let digits: Substring
        if rest.hasSuffix(".png") {
            digits = rest.dropLast(4)
        } else if rest.hasSuffix(".png.tmp") {
            digits = rest.dropLast(8)
        } else {
            return nil
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Timestamp.parseRecordingIDPrefix(String(parts[0]))
    }

    public func save(_ png: Data, number: Int) throws -> String {
        let name = "\(Timestamp(now()).recordingIDPrefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())_\(number).png"
        let target = directory.appendingPathComponent(name)
        let temporary = target.path + ".tmp"
        try lock.withLock {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            defer { unlink(temporary) }
            let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let written = png.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard written == png.count, rename(temporary, target.path) == 0 else { throw POSIXError(.EIO) }
        }
        return target.path
    }

    /// Deletes a screenshot this store saved, such as one replaced by a newer composite of
    /// the same window. Anything else is left alone.
    @discardableResult
    public func discard(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              Self.parse(url.lastPathComponent) != nil, !url.lastPathComponent.hasSuffix(".tmp") else { return false }
        return lock.withLock { unlink(path) == 0 }
    }

    @discardableResult
    public func cleanup() -> Int {
        let cutoff = Timestamp(now()).adding(seconds: -Double(retentionDays) * 86_400)
        return lock.withLock {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
            var removed = 0
            for name in names {
                guard let created = Self.parse(name), created < cutoff else { continue }
                if unlink(directory.appendingPathComponent(name).path) == 0 { removed += 1 }
            }
            return removed
        }
    }
}
