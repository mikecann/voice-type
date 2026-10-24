import Foundation
import Testing
@testable import VoiceTypeCore

// Ported from tests/test_platform_mac_drawing.py.

final class TestClock: @unchecked Sendable {
    var now = 100.0
}

final class StrokeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var strokes_: [Stroke] = []
    func add(_ stroke: Stroke) { lock.withLock { strokes_.append(stroke) } }
    var strokes: [Stroke] { lock.withLock { strokes_ } }
}

struct InkTrackerTests {
    let clock = TestClock()
    let finished = StrokeCollector()
    let ink: InkTracker

    init() {
        let clock = self.clock, finished = self.finished
        ink = InkTracker(clock: { clock.now }, maxMarks: 3, onStroke: { finished.add($0) })
    }

    @discardableResult
    func drag(_ start: (Double, Double), _ end: (Double, Double)) -> [(swallow: Bool, keep: Bool)] {
        var results = [ink.handleMouse(.down, start.0, start.1)]
        clock.now += 0.1
        results.append(ink.handleMouse(.drag, (start.0 + end.0) / 2, (start.1 + end.1) / 2))
        results.append(ink.handleMouse(.drag, end.0, end.1))
        clock.now += 0.1
        results.append(ink.handleMouse(.up, end.0, end.1))
        return results
    }

    @Test func mousePassesThroughWithoutASession() {
        #expect(ink.handleMouse(.down, 1, 1) == (false, false))
        #expect(ink.handleMouse(.up, 1, 1) == (false, false))
        #expect(!ink.needsTap)
    }

    @Test func everyButtonEventIsSwallowedDuringASession() {
        ink.begin()
        #expect(drag((0, 0), (100, 0)).allSatisfy { $0 == (true, true) })
    }

    @Test func aDragAlreadyUnderWayAtKeyDownFinishesInTheApp() {
        // The app saw this drag's mouse-down, so it must see the rest of it, or it's left
        // holding a button that was let go long ago.
        ink.begin()
        #expect(ink.handleMouse(.drag, 5, 5) == (false, true))
        #expect(ink.handleMouse(.up, 5, 5) == (false, true))
        #expect(ink.takeStrokes().isEmpty)
        // The next click is ours again.
        #expect(ink.handleMouse(.down, 9, 9) == (true, true))
    }

    @Test func eachDragBecomesANumberedStroke() {
        ink.begin()
        drag((0, 0), (100, 0))
        _ = ink.handleMouse(.down, 300, 300)
        _ = ink.handleMouse(.up, 301, 300)
        let strokes = ink.takeStrokes()
        #expect(strokes.map(\.number) == [1, 2])
        #expect(strokes.map(\.kind) == [.arrow, .point])
        #expect(finished.strokes.map(\.number) == [1, 2])
        #expect(abs(strokes[0].endedAt - 100.2) < 1e-9)
        #expect(abs(strokes[0].startedAt - 100.0) < 1e-9)
    }

    @Test func marksAreCapped() {
        ink.begin()
        for i in 0..<5 { drag((0, Double(i) * 50), (100, Double(i) * 50)) }
        #expect(ink.takeStrokes().count == 3)
    }

    @Test func releaseMidDragEndsTheMarkAndOwesOneMouseUp() {
        ink.begin()
        _ = ink.handleMouse(.down, 0, 0)
        _ = ink.handleMouse(.drag, 80, 0)
        #expect(ink.end())
        #expect(finished.strokes.count == 1)
        #expect(ink.needsTap)
        // Still dragging after release: the app never saw the down.
        #expect(ink.handleMouse(.drag, 90, 0) == (true, true))
        #expect(ink.handleMouse(.up, 90, 0) == (true, false))
        #expect(!ink.needsTap)
        #expect(ink.handleMouse(.down, 5, 5) == (false, false))
    }

    @Test func aNewClickCancelsAnOwedMouseUp() {
        ink.begin()
        _ = ink.handleMouse(.down, 0, 0)
        ink.end()
        #expect(ink.handleMouse(.down, 5, 5) == (false, false))
        #expect(!ink.needsTap)
    }

    @Test func anOwedMouseUpExpires() {
        ink.begin()
        _ = ink.handleMouse(.down, 0, 0)
        ink.end()
        #expect(!ink.expirePendingUp())
        clock.now += 10
        #expect(ink.expirePendingUp())
        #expect(!ink.needsTap)
    }

    @Test func aPressOwedFromTheLastSessionStaysOurs() {
        ink.begin()
        _ = ink.handleMouse(.down, 0, 0)
        ink.end()
        // The next dictation starts before that button comes up.
        ink.begin()
        #expect(ink.handleMouse(.drag, 5, 0) == (true, true))
        #expect(ink.handleMouse(.up, 5, 0) == (true, true))
        #expect(ink.takeStrokes().isEmpty)
    }

    @Test func aTapTimeoutGivesUpTheButton() {
        ink.begin()
        _ = ink.handleMouse(.down, 0, 0)
        _ = ink.handleMouse(.drag, 40, 0)
        ink.forgetButton()
        #expect(finished.strokes.count == 1)
        // The app may have seen a fresh mouse-down while the tap was off.
        #expect(ink.handleMouse(.up, 50, 0) == (false, true))
        #expect(ink.isActive)
    }

    @Test func releaseWithNoButtonDownLetsTheTapGo() {
        ink.begin()
        drag((0, 0), (100, 0))
        #expect(!ink.end())
        #expect(!ink.needsTap)
    }

    @Test func resetStopsAllSwallowing() {
        ink.begin()
        _ = ink.handleMouse(.down, 0, 0)
        ink.reset()
        #expect(!ink.needsTap)
        #expect(ink.handleMouse(.up, 0, 0) == (false, false))
    }

    @Test func snapshotShowsTheStrokeInProgress() {
        ink.begin()
        let before = ink.snapshot().version
        _ = ink.handleMouse(.down, 0, 0)
        _ = ink.handleMouse(.drag, 10, 0)
        let snapshot = ink.snapshot()
        #expect(snapshot.version > before)
        #expect(snapshot.strokes.isEmpty)
        #expect(snapshot.current == pts([(0, 0), (10, 0)]))
    }

    @Test func dragSamplesUnderAPointApartAreSkipped() {
        ink.begin()
        _ = ink.handleMouse(.down, 0, 0)
        _ = ink.handleMouse(.drag, 0.4, 0.4)
        _ = ink.handleMouse(.drag, 3, 0)
        #expect(ink.snapshot().current == pts([(0, 0), (3, 0)]))
    }
}

/// The session glue, with the mouse tap faked out.
final class DrawingHarness: @unchecked Sendable {
    let clock = TestClock()
    var keyDown = false
    private(set) var tapStates: [Bool] = []
    private(set) var arms = 0
    let tracker: InkTracker
    let session: DrawingSession

    init() {
        let clock = self.clock
        tracker = InkTracker(clock: { clock.now })
        session = DrawingSession(tracker: tracker)
        session.attach(setTap: { [unowned self] in self.tapStates.append($0) }, isKeyDown: { [unowned self] in self.keyDown },
                       armWatchdog: { [unowned self] in self.arms += 1 })
    }
}

struct DrawingSessionTests {
    let h = DrawingHarness()

    @Test func sessionStartsOnlyWhileTheKeyIsDown() {
        #expect(!h.session.begin())
        h.keyDown = true
        #expect(h.session.begin())
        #expect(h.tapStates == [true])
        #expect(h.arms == 1)
    }

    @Test func withoutAMouseTapNothingStarts() {
        let session = DrawingSession(tracker: InkTracker(clock: { 0 }))
        #expect(!session.isAvailable)
        #expect(!session.begin())
    }

    @Test func endTakesMarksAndTurnsTheTapOff() {
        h.keyDown = true
        _ = h.session.begin()
        #expect(h.session.handleMouse(.down, 10, 10))
        #expect(h.session.handleMouse(.up, 10, 10))
        h.keyDown = false
        #expect(h.session.end().count == 1)
        #expect(h.tapStates.last == false)
    }

    @Test func theTapThreadStopsDrawingTheMomentTheKeyGoesUp() {
        h.keyDown = true
        _ = h.session.begin()
        _ = h.session.handleMouse(.down, 10, 10)
        _ = h.session.handleMouse(.up, 12, 10)
        h.keyDown = false
        h.session.keyReleased()
        #expect(h.tapStates == [true, false])
        // A click straight after release reaches the app.
        #expect(!h.session.handleMouse(.down, 50, 50))
        // The controller still gets the mark, and nothing is switched twice.
        #expect(h.session.end().count == 1)
        #expect(h.tapStates == [true, false])
    }

    @Test func releasingMidDragKeepsTheTapForTheOwedMouseUp() {
        h.keyDown = true
        _ = h.session.begin()
        _ = h.session.handleMouse(.down, 0, 0)
        _ = h.session.handleMouse(.drag, 50, 0)
        h.keyDown = false
        h.session.keyReleased()
        #expect(h.tapStates == [true])
        #expect(h.session.handleMouse(.up, 60, 0))
        #expect(h.tapStates == [true, false])
        #expect(h.session.end().count == 1)
    }

    @Test func watchdogReleasesASessionLeftBehindByAMissedKeyUp() {
        h.keyDown = true
        _ = h.session.begin()
        h.keyDown = false
        #expect(!h.session.watchdog())
        #expect(!h.tracker.needsTap)
        #expect(h.tapStates.last == false)
    }

    @Test func watchdogLetsAnOwedMouseUpGoAfterFiveSeconds() {
        h.keyDown = true
        _ = h.session.begin()
        _ = h.session.handleMouse(.down, 0, 0)
        h.keyDown = false
        h.session.keyReleased()
        #expect(h.session.watchdog())
        h.clock.now += 6
        #expect(!h.session.watchdog())
        #expect(h.tapStates == [true, false])
    }

    @Test func aTapTimeoutGivesUpTheButtonAndComesBackForTheSession() {
        h.keyDown = true
        _ = h.session.begin()
        _ = h.session.handleMouse(.down, 0, 0)
        _ = h.session.handleMouse(.drag, 40, 0)
        h.session.mouseTapDisabled()
        // macOS switched it off; the session still needs it, so it goes back on.
        #expect(h.tapStates == [true, true])
        #expect(!h.session.handleMouse(.up, 50, 0))
        #expect(h.session.end().count == 1)
    }

    @Test func aTimeoutAfterTheSessionLeavesTheTapOff() {
        h.keyDown = true
        _ = h.session.begin()
        h.keyDown = false
        h.session.keyReleased()
        h.session.mouseTapDisabled()
        #expect(h.tapStates == [true, false])
    }

    @Test func wakeAndKeyboardTimeoutsResetDrawing() {
        h.keyDown = true
        _ = h.session.begin()
        _ = h.session.handleMouse(.down, 10, 10)
        h.session.reset()
        #expect(!h.tracker.needsTap)
        #expect(h.tapStates.last == false)
        #expect(!h.session.handleMouse(.up, 10, 10))
    }
}

struct PasteSequenceTests {
    let board = FakePasteboard([[("public.utf8-plain-text", Data("old clipboard".utf8))]])
    let env = FakePasteEnvironment()
    let clock = ManualExecutor()
    let png1 = Data("png one".utf8)
    let png2 = Data("png two".utf8)
    let logs = PasterTests.Logs()

    func paster() -> Paster {
        Paster(pasteboard: board, environment: env, now: { [clock] in clock.now }, sleep: { [clock] in clock.sleep($0) },
               log: { [logs] in logs.lines.append($0) }, readTimeout: 0.05)
    }

    final class Reads: @unchecked Sendable { var items: [[(type: String, data: Data)]] = [] }

    func targetReads(_ reads: Reads) -> () -> Void {
        { [board] in
            board.read()
            reads.items.append(board.items.first ?? [])
        }
    }

    @Test func textThenEachImageInOrderThenTheClipboardIsPutBack() throws {
        let reads = Reads()
        env.onCommandV = targetReads(reads)
        let before = clock.now
        let outcome = try paster().pasteSequence(text: "see [1] and [2]", images: [png1, png2], into: nil)
        #expect(outcome.landed && outcome.pasted == 3 && outcome.total == 3)
        #expect(reads.items.map { $0.first!.type } == ["public.utf8-plain-text", "public.png", "public.png"])
        #expect(reads.items.map { $0.first!.data } == [Data("see [1] and [2]".utf8), png1, png2])
        #expect(board.texts == ["old clipboard"])
        // A gap before each image and after the last one, plus the hand-overs and settles.
        #expect(clock.now - before >= 3 * Paster.imageGap)
        #expect(env.sounds == 0)
    }

    @Test func aCopyPartWayThroughStopsTheSequenceAndIsKept() throws {
        let reads = Reads()
        let read = targetReads(reads)
        env.onCommandV = { [board] in
            read()
            board.copyNewer("user copy")
        }
        let outcome = try paster().pasteSequence(text: "words", images: [png1], into: nil)
        #expect(!outcome.landed && outcome.pasted == 1)
        #expect(reads.items.count == 1)
        #expect(board.texts == ["user copy"])
        #expect(env.sounds == 1)
    }

    @Test func imagesOnly() throws {
        let reads = Reads()
        env.onCommandV = targetReads(reads)
        let outcome = try paster().pasteSequence(text: "  ", images: [png1], into: nil)
        #expect(outcome.landed && outcome.pasted == 1 && outcome.total == 1)
        #expect(reads.items.map { $0.first!.data } == [png1])
        #expect(board.texts == ["old clipboard"])
        // Only text gets the focus check.
        #expect(env.focusCalls == 0)
    }

    @Test func textThatFoundNoTextBoxStopsBeforeTheImages() throws {
        let reads = Reads()
        env.onCommandV = targetReads(reads)
        env.focusReadings = [FocusReading(.notEditable, role: "AXWebArea")]
        let outcome = try paster().pasteSequence(text: "words", images: [png1], into: nil)
        #expect(!outcome.landed && outcome.pasted == 1)
        #expect(reads.items.count == 1)
        #expect(board.texts == ["words"])
    }

    @Test func anImageTheTargetNeverReadsIsLeftOnTheClipboard() throws {
        var calls = 0
        let reads = Reads()
        let read = targetReads(reads)
        env.onCommandV = {
            calls += 1
            if calls == 1 { read() }
        }
        let outcome = try paster().pasteSequence(text: "words", images: [png1, png2], into: nil)
        #expect(!outcome.landed && outcome.pasted == 1)
        #expect(calls == 2)
        #expect(board.items.map { $0.map(\.type) } == [["public.png"]])
        #expect(board.items.first?.first?.data == png1)
    }

    @Test func aScreenshotThatIsNeverReadSaysWhatHadFocusThen() throws {
        var calls = 0
        let reads = Reads()
        let read = targetReads(reads)
        env.onCommandV = {
            calls += 1
            if calls == 1 { read() }
        }
        // A text box for the text; by the screenshot's Cmd+V a click had moved focus to a button.
        env.focusReadings = [FocusReading(.editable, role: "AXTextArea"), FocusReading(.notEditable, role: "AXButton")]
        let outcome = try paster().pasteSequence(text: "words", images: [png1, png2], into: TargetApp(pid: 42, name: "T3 Code"))
        #expect(!outcome.landed && outcome.pasted == 1)
        #expect(outcome.focusRole == "AXButton")
        #expect(outcome.focusMiss == FocusMiss(app: "T3 Code", role: "AXButton", item: "screenshot"))
        let line = try #require(logs.lines.first { $0.hasPrefix("Paste with screenshots stopped") })
        #expect(line.hasPrefix("Paste with screenshots stopped after 1 of 3 item(s) (the target never read the screenshot within 0.1s: gave up "))
        #expect(line.contains("; target 'T3 Code' pid 42, frontmost 'T3 Code' pid 42; focus AXButton (not-editable); main thread answered in 2 ms; clipboard unchanged since the offer)"))
        #expect(logs.lines.last == "T3 Code didn't take the paste: the focus was on a button (AXButton), not a text box. The screenshot is on the clipboard: click the text box and press Cmd+V.")
    }

    @Test func screenshotsAloneSayTheirFocusWasNotChecked() throws {
        let reads = Reads()
        let read = targetReads(reads)
        env.onCommandV = read
        _ = try paster().pasteSequence(text: "", images: [png1], into: nil)
        #expect(logs.lines.last == "NSPasteboard+Cmd+V: 0 chars and 1 screenshot(s) injected (focus not checked)")
        // A copy part way through stops them before any check too.
        env.onCommandV = { [board] in
            read()
            board.copyNewer("user copy")
        }
        let outcome = try paster().pasteSequence(text: "", images: [png1, png2], into: nil)
        #expect(!outcome.landed)
        #expect(logs.lines.last == "Paste with screenshots stopped after 1 of 2 item(s) (something else was copied, focus not checked). The next item is left on the clipboard.")
        #expect(outcome.focusMiss == nil)
    }

    @Test func aDeniedClipboardKeepsTheTextRatherThanWipingIt() throws {
        board.readability = .denied
        let reads = Reads()
        env.onCommandV = targetReads(reads)
        let outcome = try paster().pasteSequence(text: "words", images: [png1], into: nil)
        #expect(outcome.landed && outcome.clipboard == .denied)
        #expect(board.texts == ["words"])
    }

    @Test func refocusesTheKeyDownAppFirst() throws {
        let reads = Reads()
        env.onCommandV = targetReads(reads)
        env.front = 7
        let outcome = try paster().pasteSequence(text: "words", images: [png1], into: TargetApp(pid: 42, name: "T3"))
        #expect(outcome.refocused)
        #expect(env.activations.map(\.pid) == [42])
    }
}
