import Foundation

/// One dictation the Python app saved: a float WAV plus a JSON file next to it (see
/// recording_archive.py). Read-only here.
public struct SavedRecording: Sendable {
    public var id: String
    public var createdAt: String
    public var audioURL: URL
    public var durationSec: Double
    /// captured, completed, skipped_low_level, flatline_capture, finished_without_text, ...
    public var status: String
    /// The text the Python app typed, when it typed anything.
    public var text: String?
    /// The text before screen-mark markers like "[1]" were added. Same as text without marks.
    public var decodedText: String?
    public var rawTranscript: String?
    public var markCount: Int

    /// What the Python app's text was before anything native doesn't do yet. Markers for
    /// screen marks arrive in phase 2, so dictations with marks compare without them.
    public var comparableText: String {
        if markCount > 0, let decodedText { return decodedText }
        return text ?? ""
    }
}

public enum RecordingArchiveReader {
    /// Recordings created on or after `since`, oldest first.
    ///
    /// `since` is compared with the start of each recording's UTC created_at, so
    /// "2026-10-20" means from midnight UTC, as the benchmark's build_review_batch.py reads it.
    public static func list(in directory: URL, since: String) throws -> [SavedRecording] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return names.compactMap { name -> SavedRecording? in
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = meta["id"] as? String,
                  let createdAt = meta["created_at"] as? String,
                  let audioFile = meta["audio_file"] as? String else { return nil }
            guard createdAt >= since else { return nil }
            return SavedRecording(
                id: id,
                createdAt: createdAt,
                audioURL: directory.appendingPathComponent(audioFile),
                durationSec: meta["duration_seconds"] as? Double ?? 0,
                status: meta["status"] as? String ?? "",
                text: meta["text"] as? String,
                decodedText: meta["decoded_text"] as? String,
                rawTranscript: meta["raw_transcript"] as? String,
                markCount: meta["mark_count"] as? Int ?? 0
            )
        }
    }
}
