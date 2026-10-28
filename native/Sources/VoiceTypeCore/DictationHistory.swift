import Foundation

/// One dictation in the History window.
public struct HistoryItem: Identifiable, Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Words were typed.
        case typed
        /// The gates kept it from Whisper, or Whisper heard nothing to type.
        case nothingTyped
        /// The microphone gave no audio.
        case noAudio
        case failed
        /// Saved, but never transcribed (the app went down first, and recovery hasn't run).
        case notTranscribed
    }

    /// The recording's id, or the history line's time when there's no recording.
    public var id: String
    /// Set when the audio and its JSON are still on disk (30 days, if recordings are on).
    public var recordingID: String?
    public var date: Date
    /// What was typed, "" when nothing was.
    public var text: String
    public var outcome: Outcome
    public var durationSec: Double?
    public var audioURL: URL?
    /// The screenshots that were pasted with it, if they're still on disk (7 days).
    public var screenshots: [URL]
    /// What Mike says it should have been ("Fix it").
    public var correctedText: String?
    /// History's "Transcribe again".
    public var retranscribedText: String?
    public var recovered: Bool

    /// The text to show and copy: the fix if there is one, else what was typed, else what
    /// "Transcribe again" got.
    public var bestText: String { correctedText ?? (text.isEmpty ? retranscribedText ?? "" : text) }
}

/// Builds the History window's list from the recordings (30 days, with audio) and
/// transcription-history.jsonl (500 lines, for dictations made with recordings off). Only
/// reads: it never rewrites the history file, which the finaliser appends to.
public enum DictationHistory {
    /// A history line and a recording are the same dictation when the text matches and the
    /// line was written within this long of the recording (the final pass, markers and the
    /// screenshots all come between).
    static let matchWindowSeconds = 180.0

    public static func load(recordings: URL, historyFile: URL, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [HistoryItem] {
        var items = loadRecordings(recordings, fileExists: fileExists)
        // Text-only lines the recordings don't already cover.
        var unmatched: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where item.outcome == .typed {
            unmatched[item.text, default: []].append(index)
        }
        var claimed = Set<Int>()
        for line in historyLines(historyFile) {
            let candidates = unmatched[line.text] ?? []
            if let match = candidates.first(where: { !claimed.contains($0) && abs(items[$0].date.timeIntervalSince(line.date)) <= matchWindowSeconds }) {
                claimed.insert(match)
                continue
            }
            items.append(HistoryItem(id: "history:\(line.createdAt)", recordingID: nil, date: line.date, text: line.text, outcome: .typed,
                                     durationSec: nil, audioURL: nil, screenshots: [], correctedText: nil, retranscribedText: nil,
                                     recovered: false))
        }
        return items.sorted { $0.date > $1.date }
    }

    static func loadRecordings(_ directory: URL, fileExists: (String) -> Bool) -> [HistoryItem] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".json") }
        return names.compactMap { name -> HistoryItem? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return item(from: meta, directory: directory, fileExists: fileExists)
        }
    }

    static func item(from meta: [String: Any], directory: URL, fileExists: (String) -> Bool) -> HistoryItem? {
        guard let id = meta["id"] as? String, let createdAt = meta["created_at"] as? String,
              let parsed = Timestamp.parseISO(createdAt) else { return nil }
        let status = meta["status"] as? String ?? ""
        let text = (meta["text"] as? String).map(PythonText.strip) ?? ""
        let outcome: HistoryItem.Outcome
        switch status {
        case "completed": outcome = text.isEmpty ? .nothingTyped : .typed
        case "skipped_low_level", "finished_without_text": outcome = .nothingTyped
        case "flatline_capture": outcome = .noAudio
        case "captured": outcome = .notTranscribed
        default: outcome = .failed
        }
        let audio = (meta["audio_file"] as? String).map { directory.appendingPathComponent($0) }
        let shots = (meta["screenshots"] as? [String] ?? []).filter(fileExists).map { URL(fileURLWithPath: $0) }
        return HistoryItem(
            id: id, recordingID: id, date: parsed.timestamp(assumingOffset: 0).date, text: text, outcome: outcome,
            durationSec: meta["duration_seconds"] as? Double,
            audioURL: audio.flatMap { fileExists($0.path) ? $0 : nil },
            screenshots: shots,
            correctedText: meta["corrected_text"] as? String,
            retranscribedText: meta["retranscribed_text"] as? String,
            recovered: meta["recovered"] as? Bool ?? false
        )
    }

    struct Line {
        var createdAt: String
        var date: Date
        var text: String
    }

    /// The history file's lines, without TranscriptionHistory's compaction (that rewrites
    /// the file, and only the finaliser's copy should ever write it).
    static func historyLines(_ url: URL) -> [Line] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let offset = TimeZone.current.secondsFromGMT()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { raw in
            guard let item = try? OrderedJSONParser.parse(Data(raw.utf8)),
                  let createdAt = item["created_at"]?.stringValue, let text = item["text"]?.stringValue,
                  let parsed = Timestamp.parseISO(createdAt) else { return nil }
            let stripped = PythonText.strip(text)
            guard !stripped.isEmpty else { return nil }
            return Line(createdAt: createdAt, date: parsed.timestamp(assumingOffset: offset).date, text: stripped)
        }
    }
}

/// "Fix it" in the History window: what a dictation should have said, kept as a labelled
/// clip for the benchmark (~/dev/me/voice-type-benchmark labels clips the same way, by
/// recording id and the right text).
///
/// The fix goes into the recording's JSON as `corrected_text`, and the recording is copied
/// into `labelled/` next to `recordings/`, which nothing cleans up, so the clip outlives the
/// recordings' 30 days.
public enum DictationLabels {
    public static var directory: URL { VoiceTypePaths.dataDirectory.appendingPathComponent("labelled") }

    public static func save(_ correctedText: String, for recordingID: String, archive: RecordingArchive,
                            labelled: URL = directory, clock: () -> Date = Date.init) throws {
        let text = PythonText.strip(correctedText)
        try archive.update(recordingID, [("corrected_text", .string(text)), ("corrected_at", .string(Timestamp(clock()).utcISOFormat))])
        guard let entry = archive.entry(recordingID), let audioFile = entry["audio_file"]?.stringValue else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: labelled, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in [audioFile, "\(recordingID).json"] {
            let target = labelled.appendingPathComponent(name)
            try? manager.removeItem(at: target)
            try manager.copyItem(at: archive.directory.appendingPathComponent(name), to: target)
        }
    }
}
