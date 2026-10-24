import AppKit
import CoreGraphics
import VoiceTypeCore

/// What the capture worker needs from macOS, ported from mark_capture.py's Quartz helpers.
/// All of it is safe off the main thread.
enum MacScreen {
    static let screencaptureTimeout = 5.0

    /// On-screen windows, front to back.
    static func windows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
            return WindowInfo(number: number, ownerPID: (entry[kCGWindowOwnerPID as String] as? Int).map(Int32.init) ?? -1,
                              ownerName: entry[kCGWindowOwnerName as String] as? String, layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                              alpha: entry[kCGWindowAlpha as String] as? Double ?? 1,
                              bounds: MarkRect(bounds.origin.x, bounds.origin.y, bounds.width, bounds.height))
        }
    }

    /// Active displays in Quartz global points.
    static func displays() -> [MarkRect] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let b = CGDisplayBounds(id)
            return MarkRect(b.origin.x, b.origin.y, b.width, b.height)
        }
    }

    /// What's under a mark, without ink: the capture and what it was of.
    static func capture(_ stroke: Stroke) throws -> (png: Data, target: CaptureTarget)? {
        guard let target = CaptureTarget.choose(for: stroke, windows: windows(), displays: displays(), ownPID: getpid()) else { return nil }
        return (try screencapture(target.args), target)
    }

    struct CaptureFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `screencapture` and returns the PNG it wrote. It's Apple's supported tool and
    /// still works on macOS 26, where CGWindowListCreateImage is obsoleted. -x: no shutter
    /// sound. -t png: the format we paste.
    static func screencapture(_ args: [String]) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-type-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png"] + args + [path.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + screencaptureTimeout) == .success else {
            process.terminate()
            throw CaptureFailed(message: "screencapture took over \(Int(screencaptureTimeout))s")
        }
        guard process.terminationStatus == 0 else {
            let why = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CaptureFailed(message: "screencapture exited \(process.terminationStatus)\(why.isEmpty ? "" : ": \(why)")")
        }
        return try Data(contentsOf: path)
    }

    /// Whether Voice Type Native may capture other apps' windows (Screen Recording).
    static var captureAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording, which shows the system prompt the first time and
    /// adds Voice Type Native to the list in System Settings.
    static func requestCapture() {
        DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
    }
}
