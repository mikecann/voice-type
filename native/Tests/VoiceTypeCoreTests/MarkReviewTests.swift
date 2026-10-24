import Foundation
import Testing
@testable import VoiceTypeCore

// What two reviews of phase 2 found: the optional word timing work could hang or delay a
// dictation with marks, the finalisation deadline ignored marks, the timing context loaded
// for marks that could never be captured, the drawing watchdog could end a session that had
// just begun, and the ink redrew every display at 60 fps.

struct MarkFinaliseTimingTests {
    @Test func aHungTimingPassStillSavesAndPastesTheWords() throws {
        let f = try FinaliseHarness()
        f.h.transcriber.timingHangs = true
        f.finish(f.marks())
        // The final pass's token timestamps place the markers instead.
        let sequence = try #require(f.h.paster.sequences.first)
        #expect(sequence.text == "This button [1] is broken and this [2] one too")
        #expect(sequence.images.count == 2)
        #expect(try f.h.history.load().last?.text == "This button [1] is broken and this [2] one too")
        #expect(f.recording?["status"] == .string("completed"))
        #expect(f.h.transcriber.lastTimingPass?.timedOut == true)
        #expect(f.h.transcriber.lastTimingPass?.abort.isSet == true)
        #expect(f.logs.contains("The word timing pass took over 4.4s; placing markers with the final pass's token timestamps instead."))
        #expect(f.logs.contains("Placed 2 mark marker(s) using token timestamp word timings."))
    }

    @Test func theTimingPassGetsTheFinalPassesPromptAndABoundedTime() throws {
        let f = try FinaliseHarness()
        f.finish(f.marks())
        // The word list's tokens as the final pass used them (the scripted engine's [1, 2, 3]).
        #expect(f.h.transcriber.timingPromptTokens == [[1, 2, 3]])
        #expect(f.h.transcriber.timingTimeouts == [Deadlines.wordTiming(durationSec: 4)])
    }

    @Test func roughMarkerTimingsNeverRunTheTimingPass() throws {
        let f = try FinaliseHarness(settings: .object([("audio_recording_enabled", .bool(true)),
                                                       ("native", .object([("marker_timings", .string("rough"))]))]))
        f.h.transcriber.timingTranscript = Transcript(segments: [])
        f.finish(f.marks())
        #expect(f.h.transcriber.timingPasses == 0)
        #expect(f.h.paster.sequences.first?.text == "This button [1] is broken and this [2] one too")
        #expect(f.logs.contains("Placed 2 mark marker(s) using token timestamp word timings."))
    }

    @Test func withoutScreenRecordingThereIsNoTimingPass() throws {
        let f = try FinaliseHarness()
        f.finish(f.marks([1: nil, 2: nil], permissionMissing: true))
        #expect(f.h.transcriber.timingPasses == 0)
    }

    /// One mark still being captured at key-up.
    func pendingMark(waitTimeout: Double = 0.05) -> (DictationMarks, CaptureSession) {
        let strokes = [Stroke(points: pts([(0, 0)]), startedAt: 10.2, endedAt: 10.7, number: 1)]
        let session = CaptureSession(ident: 1)
        _ = session.expect(strokes)
        let marks = DictationMarks(strokes: strokes, session: session, audioOrigin: 10)
        marks.waitTimeout = waitTimeout
        marks.waitPerMark = 0
        return (marks, session)
    }

    @Test func withTheContextLoadedThePassStartsWhileTheCapturesFinishAndStopsIfTheyFail() throws {
        let f = try FinaliseHarness()
        let (marks, _) = pendingMark()
        f.finish(marks)
        #expect(f.h.transcriber.timingPasses == 1)
        #expect(f.h.transcriber.lastTimingPass?.abort.isSet == true)
        #expect(f.h.paster.pasted.map(\.text) == ["This button is broken and this one too"])
    }

    @Test func withoutItThePassWaitsForAScreenshotSoNothingLoadsForAFailedCapture() throws {
        let f = try FinaliseHarness()
        f.h.transcriber.wordTimingsLoaded = false
        let (marks, _) = pendingMark()
        f.finish(marks)
        #expect(f.h.transcriber.timingPasses == 0)
    }

    @Test func aScreenshotThatLandsDuringTheWaitStillGetsTheTimingPass() throws {
        let f = try FinaliseHarness()
        f.h.transcriber.wordTimingsLoaded = false
        let (marks, session) = pendingMark(waitTimeout: 10)
        let shot = f.shots[0]
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { _ = session.record(shot, for: [1]) }
        f.finish(marks)
        #expect(f.h.transcriber.timingPasses == 1)
        #expect(f.h.paster.sequences.first?.text == "This button [1] is broken and this one too")
    }
}

struct MarkControllerTests {
    func dictateWithOneMark(_ h: ControllerHarness, _ marks: FakeMarkSessions) throws {
        let shot = h.directory.appendingPathComponent("shot.png")
        try Data("png".utf8).write(to: shot)
        marks.toHandOver = DictationMarks(strokes: [Stroke(points: pts([(0, 0)]), startedAt: 0, endedAt: 0.2, number: 1)],
                                          session: settledSession([1: shot.path]), audioOrigin: 0)
        h.dictate(ControllerHarness.speech(seconds: 1))
    }

    @Test func aDictationWithMarksGetsALongerDeadline() throws {
        let marks = FakeMarkSessions()
        let h = try ControllerHarness(marks: marks)
        h.startAndBecomeReady()
        h.dictate(ControllerHarness.speech(seconds: 1))
        try dictateWithOneMark(h, marks)
        let deadlines = h.watchdogs.filter { $0.name == "finalization" }.map(\.timeout)
        #expect(deadlines == [30, Deadlines.finalisation(durationSec: 1, marks: 1)])
        #expect(deadlines[1] > 30)
    }

    @Test func theMarkerTimingsSettingDecidesWhetherMarksLoadTheTimingContext() throws {
        let marks = FakeMarkSessions()
        let h = try ControllerHarness(marks: marks)
        h.startAndBecomeReady()
        h.dictate(ControllerHarness.speech(seconds: 1))
        let rough = FakeMarkSessions()
        let r = try ControllerHarness(settings: .object([("native", .object([("marker_timings", .string("rough"))]))]), marks: rough)
        r.startAndBecomeReady()
        r.dictate(ControllerHarness.speech(seconds: 1))
        #expect(marks.wordTimings == [true])
        #expect(rough.wordTimings == [false])
    }

    @Test func aWakeDropsTheWordTimingContext() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        #expect(h.transcriber.timingDrops.isEmpty)
        h.controller.systemWoke()
        h.executor.drain()
        #expect(h.transcriber.timingDrops == ["wake"])
    }

    @Test func aWakeMidDictationDropsItOnceTheDictationIsDone() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.controller.systemWoke()
        #expect(h.transcriber.timingDrops.isEmpty)
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.executor.drain()
        h.release()
        #expect(h.transcriber.timingDrops == ["wake"])
    }

    @Test func otherMicrophoneRebuildsLeaveItAlone() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.controller.microphoneSettingChanged()
        h.executor.drain()
        #expect(h.transcriber.timingDrops.isEmpty)
    }
}

/// ScreenMarking with a fake capture whose outcome each test picks.
struct MarkTimingPreparationTests {
    final class Rig: @unchecked Sendable {
        let clock = TestClock()
        let directory: URL
        let drawing: DrawingSession
        let marking: ScreenMarking
        private let counter = WatchdogTests.Counter()
        var prepared: Int { counter.value }

        init(allowed: Bool = true, captures: Bool = true) throws {
            directory = try temporaryDirectory("marking-timing")
            let store = ScreenshotStore(directory: directory.appendingPathComponent("screenshots"))
            let clock = self.clock
            drawing = DrawingSession(tracker: InkTracker(clock: { clock.now }))
            let capturer = MarkCapturer(store: store, log: { _ in }, capture: { _ in
                captures ? (Data("raw".utf8), CaptureTarget(rect: MarkRect(0, 0, 10, 10), args: [], description: "test")) : nil
            }, composite: { raw, _, _ in raw }, allowed: { allowed })
            let counter = self.counter
            marking = ScreenMarking(drawing: drawing, capturer: capturer, store: store, log: { _ in }, onMark: { counter.increment() })
            drawing.attach(setTap: { _ in }, isKeyDown: { true }, armWatchdog: {})
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        /// One click, then key-up, waiting for the capture worker.
        func clickAndRelease(wordTimings: Bool = true) -> DictationMarks? {
            marking.begin(audioOrigin: 0, wordTimings: wordTimings)
            _ = drawing.handleMouse(.down, 1, 1)
            _ = drawing.handleMouse(.up, 1, 1)
            let marks = marking.finish()
            _ = marks?.numbers()
            return marks
        }
    }

    @Test func aCapturedMarkGetsTheTimingContextReady() throws {
        let rig = try Rig()
        let marks = rig.clickAndRelease()
        #expect(marks?.numbers() == [1])
        #expect(rig.prepared == 1)
    }

    @Test func withoutScreenRecordingItIsNeverLoaded() throws {
        // The first click before the permission is granted, which is first use.
        let rig = try Rig(allowed: false)
        let marks = rig.clickAndRelease()
        #expect(marks?.numbers() == [])
        #expect(marks?.mayHaveScreenshots == false)
        #expect(rig.prepared == 0)
    }

    @Test func aFailedCaptureDoesNotLoadIt() throws {
        let rig = try Rig(captures: false)
        let marks = rig.clickAndRelease()
        #expect(marks?.numbers() == [])
        #expect(marks?.mayHaveScreenshots == false)
        #expect(rig.prepared == 0)
    }

    @Test func roughTimingsNeverAskForIt() throws {
        let rig = try Rig()
        let marks = rig.clickAndRelease(wordTimings: false)
        #expect(marks?.numbers() == [1])
        #expect(rig.prepared == 0)
    }
}

struct CaptureSessionOutlookTests {
    func strokes(_ numbers: [Int]) -> [Stroke] {
        numbers.map { Stroke(points: pts([(0, 0)]), startedAt: 0, endedAt: 1, number: $0) }
    }

    @Test func mayHaveScreenshotsUntilEveryMarkHasFailed() {
        let session = CaptureSession(ident: 1)
        #expect(session.mayHaveScreenshots)
        _ = session.expect(strokes([1, 2]))
        #expect(session.mayHaveScreenshots)
        session.settle(1)
        #expect(session.mayHaveScreenshots)
        session.settle(2)
        #expect(!session.mayHaveScreenshots)
    }

    @Test func oneCaptureIsEnough() {
        let session = CaptureSession(ident: 1)
        _ = session.expect(strokes([1, 2]))
        _ = session.record("/a.png", for: [2])
        session.settle(1)
        session.settle(2)
        #expect(session.mayHaveScreenshots)
    }

    @Test func noneWithoutScreenRecording() {
        let session = CaptureSession(ident: 1)
        session.notePermissionMissing()
        #expect(!session.mayHaveScreenshots)
    }
}

struct MarkerTimingsSettingTests {
    func file(_ json: String) throws -> SettingsFile {
        SettingsFile(url: URL(fileURLWithPath: "/dev/null"), json: try OrderedJSONParser.parse(Data(json.utf8)))
    }

    @Test func accurateUnlessSetToRough() throws {
        #expect(try file("{}").markerTimings == .accurate)
        #expect(try file(#"{"native": {"marker_timings": "rough"}}"#).markerTimings == .rough)
        #expect(try file(#"{"native": {"marker_timings": " Rough "}}"#).markerTimings == .rough)
        #expect(try file(#"{"native": {"marker_timings": "accurate"}}"#).markerTimings == .accurate)
        #expect(try file(#"{"native": {"marker_timings": "fast"}}"#).markerTimings == .accurate)
        #expect(try file(#"{"native": {"marker_timings": false}}"#).markerTimings == .accurate)
        #expect(try file(#"{"native": "rough"}"#).markerTimings == .accurate)
    }
}

struct DrawingWatchdogRaceTests {
    /// The tap thread's key state, read and written from two threads.
    final class Key: @unchecked Sendable {
        private let lock = NSLock()
        private var down_ = false
        var down: Bool {
            get { lock.withLock { down_ } }
            set { lock.withLock { down_ = newValue } }
        }
    }

    @Test func theWatchdogNeverEndsASessionWhoseKeyIsDown() {
        // A key-up the watchdog saw, then a fast re-press: begin() must keep its session.
        let key = Key()
        let session = DrawingSession(tracker: InkTracker(clock: { 0 }))
        session.attach(setTap: { _ in }, isKeyDown: { key.down }, armWatchdog: {})
        let stop = AbortFlag()
        let watching = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while !stop.isSet { session.watchdog() }
            watching.signal()
        }
        var ended = 0
        for _ in 0..<20_000 {
            key.down = true
            #expect(session.begin())
            // Only the key going up may end it.
            if !session.tracker.isActive { ended += 1 }
            key.down = false
            session.keyReleased()
        }
        stop.set()
        watching.wait()
        #expect(ended == 0)
    }

    @Test func itStillEndsASessionLeftBehindByAMissedKeyUp() {
        let h = DrawingHarness()
        h.keyDown = true
        _ = h.session.begin()
        h.keyDown = false
        #expect(!h.session.watchdog())
        #expect(!h.tracker.isActive)
        #expect(h.tapStates == [true, false])
    }
}

struct InkLayerContentTests {
    let laptop = MarkRect(0, 0, 1728, 1117)
    let external = MarkRect(1728, -200, 2560, 1440)

    func click(_ x: Double, _ y: Double, number: Int = 1, endedAt: Double = 1) -> Stroke {
        Stroke(points: pts([(x, y)]), startedAt: 0, endedAt: endedAt, number: number)
    }

    @Test func aMarkOnOneDisplayLeavesTheOtherAlone() {
        let strokes = [click(100, 100)]
        let onLaptop = InkLayerContent(strokes: strokes, current: nil, screen: laptop)
        let onExternal = InkLayerContent(strokes: strokes, current: nil, screen: external)
        #expect(onLaptop.marks.count == 1)
        #expect(onExternal.isEmpty)
        #expect(onExternal.dirtyRect(since: InkLayerContent()) == nil)
        let dirty = onLaptop.dirtyRect(since: InkLayerContent())
        // Just around the ring and its badge, not the whole screen.
        #expect(dirty.map { $0.width < 100 && $0.height < 100 && $0.contains(MarkPoint(100, 100)) } == true)
    }

    @Test func nothingChangedMeansNoRedraw() {
        let strokes = [click(100, 100)]
        let a = InkLayerContent(strokes: strokes, current: [MarkPoint(300, 300), MarkPoint(320, 300)], screen: laptop)
        let b = InkLayerContent(strokes: strokes, current: [MarkPoint(300, 300), MarkPoint(320, 300)], screen: laptop)
        #expect(b.dirtyRect(since: a) == nil)
    }

    @Test func aDragRedrawsOnlyAroundTheLine() {
        let strokes = [click(100, 100)]
        let before = InkLayerContent(strokes: strokes, current: [MarkPoint(1000, 800), MarkPoint(1010, 800)], screen: laptop)
        let after = InkLayerContent(strokes: strokes, current: [MarkPoint(1000, 800), MarkPoint(1010, 800), MarkPoint(1030, 805)], screen: laptop)
        let dirty = after.dirtyRect(since: before)
        #expect(dirty != nil)
        #expect(dirty?.contains(MarkPoint(1030, 805)) == true)
        // The earlier mark at (100, 100) isn't redrawn.
        #expect(dirty?.contains(MarkPoint(100, 100)) == false)
    }

    @Test func finishingAMarkRedrawsWhereTheLineWasAndTheNewMark() {
        let line = [MarkPoint(500, 500), MarkPoint(600, 500)]
        let before = InkLayerContent(strokes: [], current: line, screen: laptop)
        let after = InkLayerContent(strokes: [Stroke(points: line, startedAt: 0, endedAt: 1, number: 1)], current: nil, screen: laptop)
        let dirty = after.dirtyRect(since: before)
        #expect(dirty != nil)
        #expect(dirty?.contains(MarkPoint(500, 500)) == true && dirty?.contains(MarkPoint(600, 500)) == true)
        // The badge behind the arrow's tail.
        #expect(dirty.map { $0.x < 500 - ScreenMarks.badgeRadius } == true)
    }

    @Test func theNextDictationsFirstMarkIsAChangeEvenWithTheSameNumber() {
        let last = InkLayerContent(strokes: [click(100, 100, endedAt: 1)], current: nil, screen: laptop)
        let next = InkLayerContent(strokes: [click(900, 600, endedAt: 50)], current: nil, screen: laptop)
        let dirty = next.dirtyRect(since: last)
        #expect(dirty != nil)
        #expect(dirty?.contains(MarkPoint(100, 100)) == true && dirty?.contains(MarkPoint(900, 600)) == true)
    }

    @Test func aMarkAcrossTwoDisplaysIsOnBoth() {
        let across = [Stroke(points: line((1700, 300), (1760, 300), steps: 10), startedAt: 0, endedAt: 1, number: 1)]
        #expect(!InkLayerContent(strokes: across, current: nil, screen: laptop).isEmpty)
        #expect(!InkLayerContent(strokes: across, current: nil, screen: external).isEmpty)
    }

    @Test func boundsCoverEverythingDrawn() {
        // A ring of 14 pt and a 4 pt line around (100, 100), its badge up and to the right.
        let shapes = ScreenMarks.inkShapes(click(100, 100))
        let bounds = InkLayerContent.bounds(shapes)
        let badge = shapes.badge
        #expect(bounds.contains(MarkPoint(100 - ScreenMarks.ringRadius - 2, 100)))
        #expect(bounds.contains(MarkPoint(badge.center.x + badge.radius, badge.center.y - badge.radius)))
    }
}
