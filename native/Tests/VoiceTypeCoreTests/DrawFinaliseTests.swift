import Foundation
import Testing
@testable import VoiceTypeCore

// Ported from tests/test_draw_finalize.py: the real finaliser with screen marks, against fakes.

/// A capture session whose worker has already settled these marks (nil for a failed one).
func settledSession(_ paths: [Int: String?], permissionMissing: Bool = false) -> CaptureSession {
    let session = CaptureSession(ident: 1)
    _ = session.expect(paths.keys.sorted().map { Stroke(points: pts([(0, 0)]), startedAt: 0, endedAt: 1, number: $0) })
    if permissionMissing { session.notePermissionMissing() }
    for (number, path) in paths {
        if let path { _ = session.record(path, for: [number]) } else { session.settle(number) }
    }
    return session
}

final class FinaliseHarness: @unchecked Sendable {
    let h: ControllerHarness
    let finaliser: Finaliser
    let shots: [String]
    private let logBox = LogBox()
    var logs: [String] { logBox.lines }

    final class LogBox: @unchecked Sendable { var lines: [String] = [] }

    init(transcript: String = "This button is broken and this one too", settings: JSONValue? = nil) throws {
        h = try ControllerHarness(settings: settings ?? .object([("audio_recording_enabled", .bool(true)), ("vocabulary", .strings(["Convex"]))]))
        h.engine.segments = [transcript]
        // One word every half second.
        h.engine.timedWords = PythonText.split(transcript).enumerated().map { i, word in TimedText(Double(i) * 0.5, Double(i) * 0.5 + 0.4, " \(word)") }
        let executor = h.executor, logBox = self.logBox, directory = h.directory
        finaliser = Finaliser(transcriber: h.transcriber, pill: h.pill, paster: h.paster, archive: h.archive, history: h.history,
                              log: { logBox.lines.append($0) }, now: { executor.now })
        shots = try (1...2).map { n in
            let url = directory.appendingPathComponent("\(n).png")
            try Data("png \(n)".utf8).write(to: url)
            return url.path
        }
    }

    /// Mark 1 finished at 0.7 s of audio (during "button"), mark 2 at 2.7 s (during "this").
    /// Audio began 10 s into the monotonic clock.
    func marks(_ paths: [Int: String?]? = nil, permissionMissing: Bool = false) -> DictationMarks {
        let strokes = [
            Stroke(points: pts([(0, 0), (100, 0)]), startedAt: 10.2, endedAt: 10.7, number: 1),
            Stroke(points: pts([(0, 0)]), startedAt: 12.5, endedAt: 12.7, number: 2),
        ]
        let session = settledSession(paths ?? [1: shots[0], 2: shots[1]], permissionMissing: permissionMissing)
        return DictationMarks(strokes: strokes, session: session, audioOrigin: 10, log: { [logBox] in logBox.lines.append($0) })
    }

    @discardableResult
    func finish(_ marks: DictationMarks?, samples: [Float] = ControllerHarness.speech(seconds: 4)) -> FinaliseOutcome {
        let settings = SettingsFile(url: h.directory.appendingPathComponent("settings.json"), json: h.settingsJSON)
        return finaliser.run(FinaliseJob(samples: samples, metadata: [("mode", .string("final_only"))], preview: "", target: TargetApp(pid: 42, name: "T3 Code"),
                                         settings: settings, keyUpAt: 0, stopAudioSeconds: 0, keyHoldSeconds: Double(samples.count) / 16_000, marks: marks))
    }

    var recording: JSONValue? { h.recordingEntries().last }
}

struct DrawFinaliseTests {
    @Test func noMarksTakesExactlyTheOldPath() throws {
        let f = try FinaliseHarness()
        f.finish(nil)
        #expect(f.h.paster.pasted.map(\.text) == ["This button is broken and this one too"])
        #expect(f.h.paster.sequences.isEmpty)
        #expect(f.h.pill.calls.last == "done:8")
        // No word timings, so Whisper runs exactly as benchmarked.
        #expect(f.h.engine.finalOptions.map(\.wordTimings) == [false])
        #expect(f.recording?["screenshots"] == nil)
    }

    @Test func marksPutMarkersInTheTextAndPasteImagesInOrder() throws {
        let f = try FinaliseHarness()
        f.finish(f.marks())
        #expect(f.h.engine.finalOptions.map(\.wordTimings) == [true])
        let sequence = try #require(f.h.paster.sequences.first)
        #expect(sequence.text == "This button [1] is broken and this [2] one too")
        #expect(sequence.images == [Data("png 1".utf8), Data("png 2".utf8)])
        #expect(f.h.paster.pasted.isEmpty)
        #expect(f.h.pill.calls.last == "done:10+2")
        #expect(f.recording?["screenshots"] == .strings(f.shots))
        #expect(f.recording?["text"] == .string("This button [1] is broken and this [2] one too"))
        #expect(f.recording?["decoded_text"] == .string("This button is broken and this one too"))
        #expect(try f.h.history.load().last?.text == "This button [1] is broken and this [2] one too")
        // No timing engine here, so the final pass's token timestamps place them.
        #expect(f.h.transcriber.timingPasses == 1)
        #expect(f.logs.contains("Placed 2 mark marker(s) using token timestamp word timings."))
    }

    @Test func theTimingPassPlacesTheMarkersWhenThereIsOne() throws {
        let f = try FinaliseHarness()
        // The DTW pass hears "broken" ending later, at 1.6 s, and "this" from 2.8 s.
        let words = ["This", "button", "is", "broken", "and", "this", "one", "too"]
        let starts = [0.0, 0.5, 1.0, 1.6, 2.4, 2.8, 3.1, 3.4]
        f.h.transcriber.timingTranscript = Transcript(segments: [
            TranscriptSegment(text: words.joined(separator: " "), startSec: 0, endSec: 4, noSpeechProb: 0, tokenProbs: [],
                              words: zip(words, starts).map { TimedText($1, $1 + 0.3, " \($0)") }),
        ])
        f.finish(f.marks())
        // Mark 2 finished at 2.7 s, before "this" in the timing pass's words.
        #expect(f.h.paster.sequences.first?.text == "This button [1] is broken and [2] this one too")
        #expect(f.logs.contains("Placed 2 mark marker(s) using DTW word timings."))
    }

    @Test func theTimingPassIsOnlyForDictationsWithMarks() throws {
        let f = try FinaliseHarness()
        f.finish(nil)
        #expect(f.h.transcriber.timingPasses == 0)
        // Nor when every capture failed: there's nothing to mark.
        f.finish(f.marks([1: nil, 2: nil]))
        #expect(f.h.transcriber.timingPasses == 0)
    }

    @Test func markersSurviveCorrections() throws {
        let f = try FinaliseHarness(settings: .object([("audio_recording_enabled", .bool(true)), ("corrections", .object([("broken", .string("busted, really"))]))]))
        f.finish(f.marks())
        #expect(f.h.paster.sequences.first?.text == "This button [1] is busted, really and this [2] one too")
    }

    @Test func marksSharingAWindowGetBothMarkersAndOneImage() throws {
        let f = try FinaliseHarness()
        f.finish(f.marks([1: f.shots[0], 2: f.shots[0]]))
        let sequence = try #require(f.h.paster.sequences.first)
        #expect(sequence.text == "This button [1] is broken and this [2] one too")
        #expect(sequence.images == [Data("png 1".utf8)])
        #expect(f.h.pill.calls.last == "done:10+1")
        #expect(f.recording?["screenshots"] == .strings([f.shots[0]]))
    }

    @Test func aFailedCaptureDropsItsMarker() throws {
        let f = try FinaliseHarness()
        f.finish(f.marks([1: nil, 2: f.shots[1]]))
        let sequence = try #require(f.h.paster.sequences.first)
        #expect(sequence.text == "This button is broken and this [2] one too")
        #expect(sequence.images == [Data("png 2".utf8)])
        #expect(f.logs.contains("Mark(s) [1] have no screenshot to paste."))
    }

    @Test func marksButNoWordsPastesJustTheImages() throws {
        let f = try FinaliseHarness(transcript: "")
        f.finish(f.marks())
        let sequence = try #require(f.h.paster.sequences.first)
        #expect(sequence.text == "")
        #expect(sequence.images == [Data("png 1".utf8), Data("png 2".utf8)])
        #expect(f.h.pill.calls.last == "done:0+2")
        #expect(f.logs.contains { $0.hasPrefix("No words (") && $0.hasSuffix("pasting 2 mark(s) on their own.") })
    }

    @Test func withoutPermissionTheTextIsStillPastedWithAHint() throws {
        let f = try FinaliseHarness()
        f.finish(f.marks([1: nil, 2: nil], permissionMissing: true))
        #expect(f.h.paster.pasted.map(\.text) == ["This button is broken and this one too"])
        #expect(f.h.paster.sequences.isEmpty)
        #expect(Array(f.h.pill.calls.suffix(2)) == ["done:8", "hint"])
    }

    @Test func aFailedImagePastePointsAtTheClipboard() throws {
        let f = try FinaliseHarness()
        f.h.paster.landed = false
        let outcome = f.finish(f.marks())
        #expect(outcome.landed == false)
        #expect(f.h.pill.calls.last == "paste_failed")
    }

    @Test func aShortQuietClipWithMarksPastesTheScreenshots() throws {
        let f = try FinaliseHarness()
        // 0.5 s just above digital silence: the short-clip gate skips it before Whisper.
        let quiet = (0..<8_000).map { $0 % 2 == 0 ? Float(0.001) : -0.001 }
        f.finish(f.marks(), samples: quiet)
        #expect(f.h.engine.finals.isEmpty)
        #expect(f.h.paster.sequences.first?.images.count == 2)
        #expect(f.h.paster.sequences.first?.text == "")
        #expect(f.recording?["status"] == .string("skipped_low_level"))
        #expect(f.logs.contains("No words (near-silent clip); pasting 2 mark(s) on their own."))
    }

    @Test func aShortQuietClipWithoutMarksIsRecordedAsBefore() throws {
        let f = try FinaliseHarness()
        let quiet = (0..<8_000).map { $0 % 2 == 0 ? Float(0.001) : -0.001 }
        f.finish(nil, samples: quiet)
        #expect(f.recording?["timings"] == nil)
        #expect(f.h.pill.calls.last == "hide")
    }

    @Test func aFlatlineCaptureKeepsTheScreenshotsButPastesNothing() throws {
        let f = try FinaliseHarness()
        f.finish(f.marks(), samples: [Float](repeating: 0, count: 16_000))
        #expect(f.h.paster.sequences.isEmpty && f.h.paster.pasted.isEmpty)
        #expect(f.logs.contains("Mark screenshots are kept on disk but not pasted."))
    }

    @Test func aMarkBeforeAnyWordGoesFirst() throws {
        let f = try FinaliseHarness()
        let strokes = [Stroke(points: pts([(0, 0)]), startedAt: 9.5, endedAt: 9.8, number: 1)]
        f.finish(DictationMarks(strokes: strokes, session: settledSession([1: f.shots[0]]), audioOrigin: 10))
        #expect(f.h.paster.sequences.first?.text == "[1] This button is broken and this one too")
    }
}

final class FakeMarkSessions: MarkSessions, @unchecked Sendable {
    var begun: [Double] = []
    var wordTimings: [Bool] = []
    var finished = 0
    var cleanedUp = 0
    var toHandOver: DictationMarks?

    func begin(audioOrigin: Double, wordTimings: Bool) {
        begun.append(audioOrigin)
        self.wordTimings.append(wordTimings)
    }
    func finish() -> DictationMarks? {
        finished += 1
        return toHandOver
    }
    func cleanUp() -> Int {
        cleanedUp += 1
        return 0
    }
}

struct ControllerDrawingTests {
    @Test func drawingStartsAfterTheMicrophoneAndEndsAtKeyUp() throws {
        let marks = FakeMarkSessions()
        let h = try ControllerHarness(marks: marks)
        h.startAndBecomeReady()
        h.press()
        #expect(h.factory.events.last == "start s1:Yeti Stereo Microphone")
        #expect(marks.begun == [h.executor.now])
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.executor.drain()
        #expect(marks.finished == 0)
        h.release()
        #expect(marks.finished == 1)
        // Nothing drawn: the recording has no mark count and the paste is the plain one.
        #expect(h.recordingEntries().last?["mark_count"] == nil)
        #expect(h.paster.pasted.count == 1)
    }

    @Test func theMarksGoToFinalisationAndTheRecording() throws {
        let marks = FakeMarkSessions()
        let h = try ControllerHarness(marks: marks)
        let shot = h.directory.appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: shot)
        marks.toHandOver = DictationMarks(strokes: [Stroke(points: pts([(0, 0)]), startedAt: 0, endedAt: 0.2, number: 1)],
                                          session: settledSession([1: shot.path]), audioOrigin: 0)
        h.startAndBecomeReady()
        h.dictate(ControllerHarness.speech(seconds: 1))
        let entry = try #require(h.recordingEntries().last)
        #expect(entry["mark_count"] == .int(1))
        // After the vocabulary, as Python wrote it, and before native's own fields.
        if case let .object(pairs) = entry {
            let keys = pairs.map(\.key)
            #expect(keys.firstIndex(of: "mark_count")! == keys.firstIndex(of: "vocabulary")! + 1)
            #expect(keys.firstIndex(of: "mark_count")! < keys.firstIndex(of: "app")!)
        }
        #expect(h.paster.sequences.first?.images == [Data("png".utf8)])
        #expect(h.engine.finalOptions.last?.wordTimings == true)
    }

    @Test func drawingOffInSettingsNeverStartsASession() throws {
        let marks = FakeMarkSessions()
        let h = try ControllerHarness(settings: .object([("draw_on_screen_enabled", .bool(false))]), marks: marks)
        h.startAndBecomeReady()
        h.dictate(ControllerHarness.speech(seconds: 1))
        #expect(marks.begun.isEmpty)
    }
}

/// ScreenMarking with a fake mouse tap and capture.
struct ScreenMarkingTests {
    final class Rig: @unchecked Sendable {
        let clock = TestClock()
        var keyDown = true
        let store: ScreenshotStore
        let directory: URL
        let drawing: DrawingSession
        let marking: ScreenMarking

        init(tap: Bool = true) throws {
            directory = try temporaryDirectory("marking")
            store = ScreenshotStore(directory: directory.appendingPathComponent("screenshots"))
            let clock = self.clock
            drawing = DrawingSession(tracker: InkTracker(clock: { clock.now }))
            let capturer = MarkCapturer(store: store, log: { _ in }, capture: { _ in
                (Data("raw".utf8), CaptureTarget(rect: MarkRect(0, 0, 10, 10), args: [], description: "test"))
            }, composite: { raw, _, strokes in raw + Data(strokes.map { UInt8($0.number) }) })
            marking = ScreenMarking(drawing: drawing, capturer: capturer, store: store, log: { _ in })
            if tap {
                drawing.attach(setTap: { _ in }, isKeyDown: { [unowned self] in self.keyDown }, armWatchdog: {})
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func aDictationsMarksAreCapturedAndHandedOver() throws {
        let rig = try Rig()
        rig.marking.begin(audioOrigin: 100, wordTimings: true)
        _ = rig.drawing.handleMouse(.down, 1, 1)
        rig.clock.now = 100.5
        _ = rig.drawing.handleMouse(.up, 1, 1)
        rig.keyDown = false
        rig.drawing.keyReleased()
        let marks = try #require(rig.marking.finish())
        #expect(marks.numbers() == [1])
        #expect(marks.audioTimes([1]) == [0.5])
        let path = try #require(marks.imagePaths().first)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("raw".utf8) + Data([1]))
    }

    @Test func nothingDrawnMeansNoMarks() throws {
        let rig = try Rig()
        rig.marking.begin(audioOrigin: 0, wordTimings: true)
        #expect(rig.marking.finish() == nil)
    }

    @Test func withoutAMouseTapNothingStarts() throws {
        let rig = try Rig(tap: false)
        rig.marking.begin(audioOrigin: 0, wordTimings: true)
        #expect(rig.marking.finish() == nil)
    }

    @Test func aKeyAlreadyUpStartsNothing() throws {
        let rig = try Rig()
        rig.keyDown = false
        rig.marking.begin(audioOrigin: 0, wordTimings: true)
        #expect(!rig.drawing.tracker.isActive)
        #expect(rig.marking.finish() == nil)
    }
}
