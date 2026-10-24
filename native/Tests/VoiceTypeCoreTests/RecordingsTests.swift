import Foundation
import Testing
@testable import VoiceTypeCore

struct RecordingsTests {
    func archive(_ entries: [[String: Any]]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vt-recordings-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries {
            let id = entry["id"] as! String
            try JSONSerialization.data(withJSONObject: entry).write(to: dir.appendingPathComponent("\(id).json"))
        }
        // Not ours, so it's ignored.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.json"))
        return dir
    }

    func entry(_ id: String, _ createdAt: String, status: String = "completed", extra: [String: Any] = [:]) -> [String: Any] {
        ["id": id, "created_at": createdAt, "audio_file": "\(id).wav", "duration_seconds": 1.5, "status": status]
            .merging(extra) { $1 }
    }

    @Test func listsFromTheUTCDateOldestFirst() throws {
        let dir = try archive([
            entry("20261021T000000000000Z_b", "2026-10-21T00:00:00.000000+00:00", extra: ["text": "B"]),
            entry("20261019T235959000000Z_a", "2026-10-19T23:59:59.000000+00:00", extra: ["text": "A"]),
            entry("20261020T000000000000Z_c", "2026-10-20T00:00:00.000000+00:00", status: "skipped_low_level"),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try RecordingArchiveReader.list(in: dir, since: "2026-10-20")
        #expect(found.map(\.id) == ["20261020T000000000000Z_c", "20261021T000000000000Z_b"])
        #expect(found[0].comparableText == "")
        #expect(found[1].comparableText == "B")
        #expect(found[1].audioURL.lastPathComponent == "20261021T000000000000Z_b.wav")
    }

    @Test func dictationsWithMarksCompareWithoutTheMarkers() throws {
        let dir = try archive([
            entry("20261023T010410076973Z_m", "2026-10-23T01:04:10.076973+00:00",
                  extra: ["text": "Look at this [1] here.", "decoded_text": "Look at this here.", "mark_count": 1]),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = try RecordingArchiveReader.list(in: dir, since: "2026-10-01")
        #expect(found.first?.comparableText == "Look at this here.")
    }
}
