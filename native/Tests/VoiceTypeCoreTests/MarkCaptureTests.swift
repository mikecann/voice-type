import Foundation
import Testing
@testable import VoiceTypeCore
import VoiceTypeImaging

// Ported from tests/test_mark_capture.py.

func arrow(_ start: (Double, Double), _ end: (Double, Double), _ number: Int = 1) -> Stroke {
    Stroke(points: line(start, end, steps: 10), startedAt: 0, endedAt: 1, number: number)
}

struct CaptureTargetTests {
    let displays = [MarkRect(0, 0, 1728, 1117), MarkRect(1728, -200, 2560, 1440)]

    @Test func capturesTheWindowUnderTheArrowTipWithoutItsShadow() throws {
        let windows = [window(99, 0, 0, 4288, 1440, number: 1), window(10, 100, 100, 800, 600, number: 42)]
        let target = try #require(CaptureTarget.choose(for: arrow((50, 50), (300, 300)), windows: windows, displays: displays, ownPID: 99))
        #expect(target.args == ["-o", "-l", "42"])
        #expect(target.rect == MarkRect(100, 100, 800, 600))
        #expect(target.description == "App10 #42")
    }

    @Test func bareDesktopCapturesARegionOfThatDisplay() throws {
        let target = try #require(CaptureTarget.choose(for: Stroke(points: pts([(2000, 0)]), startedAt: 0, endedAt: 1, number: 1),
                                                       windows: [], displays: displays, ownPID: 99))
        #expect(target.args == ["-R", "1728,-200,800,800"])
        #expect(target.rect == MarkRect(1728, -200, 800, 800))
        #expect(target.groupKey == nil)
    }

    @Test func nothingToCaptureWithoutDisplays() {
        #expect(CaptureTarget.choose(for: Stroke(points: pts([(5, 5)]), startedAt: 0, endedAt: 1), windows: [], displays: [], ownPID: 1) == nil)
    }
}

final class FakeStore: ScreenshotStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var saved: [(number: Int, png: Data)] = []
    private(set) var discarded: [String] = []

    func save(_ png: Data, number: Int) throws -> String {
        lock.withLock {
            saved.append((number, png))
            return "/shots/\(saved.count).png"
        }
    }

    func discard(_ path: String) -> Bool {
        lock.withLock { discarded.append(path) }
        return true
    }
}

func windowTarget(_ number: Int, _ rect: MarkRect = MarkRect(0, 0, 800, 600)) -> CaptureTarget {
    CaptureTarget(rect: rect, args: ["-o", "-l", String(number)], description: "App #\(number)", window: number)
}

func desktopTarget(_ rect: MarkRect = MarkRect(0, 0, 800, 800)) -> CaptureTarget {
    CaptureTarget(rect: rect, args: ["-R", "0,0,800,800"], description: "desktop 0,0,800,800")
}

final class CapturerHarness: @unchecked Sendable {
    let store = FakeStore()
    private let lock = NSLock()
    private(set) var logs: [String] = []
    private(set) var requests = 0
    private(set) var composited: [(raw: String, rect: MarkRect, numbers: [Int])] = []
    /// Each mark lands on its own desktop region unless a test says otherwise, so nothing
    /// groups by accident.
    var targets: [Int: CaptureTarget] = [:]
    var allowed = true
    var failCapture: Set<Int> = []
    var failCompositeOfGroups = false
    var holdCapture: (Int, DispatchSemaphore)?

    func log(_ s: String) { lock.withLock { logs.append(s) } }

    func capturer() -> MarkCapturer {
        MarkCapturer(store: store, log: { [unowned self] in self.log($0) }, capture: { [unowned self] stroke in
            if let (number, gate) = self.holdCapture, number == stroke.number { _ = gate.wait(timeout: .now() + 2) }
            if self.failCapture.contains(stroke.number) { throw PNGError("screencapture exited 1") }
            let target = self.targets[stroke.number] ?? desktopTarget(MarkRect(Double(stroke.number), 0, 800, 800))
            return (Data("raw\(stroke.number)".utf8), target)
        }, composite: { [unowned self] raw, rect, strokes in
            if self.failCompositeOfGroups && strokes.count > 1 { throw PNGError("the compositor fell over") }
            let numbers = strokes.map(\.number)
            self.lock.withLock { self.composited.append((String(decoding: raw, as: UTF8.self), rect, numbers)) }
            return Data("png \(String(decoding: raw, as: UTF8.self)) \(numbers)".utf8)
        }, allowed: { [unowned self] in self.allowed }, request: { [unowned self] in self.lock.withLock { self.requests += 1 } })
    }

    func runMarks(_ numbers: [Int], submitted: [Int]? = nil) -> [(number: Int, path: String)] {
        let capturer = capturer()
        capturer.begin()
        let strokes = numbers.map { arrow((0, 0), (100, 0), $0) }
        for n in submitted ?? numbers { capturer.submit(strokes[numbers.firstIndex(of: n)!]) }
        return capturer.finish(strokes)!.wait(timeout: 2)
    }
}

func pairs(_ shots: [(number: Int, path: String)]) -> [String] { shots.map { "\($0.number):\($0.path)" } }

struct MarkCapturerTests {
    let h = CapturerHarness()

    @Test func marksAreCapturedAndReturnedInOrder() {
        let capturer = h.capturer()
        capturer.begin()
        let strokes = [1, 2, 3].map { arrow((0, 0), (100, 0), $0) }
        capturer.submit(strokes[1])
        capturer.submit(strokes[0])
        let session = capturer.finish(strokes)!  // mark 3 was never handed over
        #expect(pairs(session.wait(timeout: 2)) == ["1:/shots/2.png", "2:/shots/1.png", "3:/shots/3.png"])
        #expect(!session.permissionMissing)
    }

    @Test func aMarkHandedOverTwiceIsCapturedOnce() {
        let capturer = h.capturer()
        capturer.begin()
        let stroke = arrow((0, 0), (100, 0))
        capturer.submit(stroke)
        capturer.submit(stroke)
        _ = capturer.finish([stroke])!.wait(timeout: 2)
        #expect(h.store.saved.count == 1)
    }

    @Test func twoMarksOnOneWindowShareOneScreenshotWithBothDrawn() {
        h.targets = [1: windowTarget(42), 2: windowTarget(42)]
        #expect(pairs(h.runMarks([1, 2])) == ["1:/shots/2.png", "2:/shots/2.png"])
        // The second composite draws both marks onto the newest capture.
        #expect(h.composited.last.map { "\($0.raw) \($0.numbers)" } == "raw2 [1, 2]")
        #expect(h.composited.last?.rect == MarkRect(0, 0, 800, 600))
        #expect(h.logs.contains("Marks [1, 2] share App #42: one screenshot."))
    }

    @Test func recompositingReplacesTheGroupsEarlierFile() {
        h.targets = [1: windowTarget(42), 2: windowTarget(42), 3: windowTarget(42)]
        #expect(Set(h.runMarks([1, 2, 3]).map(\.path)) == ["/shots/3.png"])
        #expect(h.store.discarded == ["/shots/1.png", "/shots/2.png"])
    }

    @Test func marksOnDifferentWindowsGetSeparateScreenshots() {
        h.targets = [1: windowTarget(42), 2: windowTarget(7)]
        #expect(pairs(h.runMarks([1, 2])) == ["1:/shots/1.png", "2:/shots/2.png"])
        #expect(h.composited.map(\.numbers) == [[1], [2]])
        #expect(h.store.discarded.isEmpty)
    }

    @Test func aWindowThatMovedBetweenMarksDoesNotGroup() {
        h.targets = [1: windowTarget(42, MarkRect(0, 0, 800, 600)), 2: windowTarget(42, MarkRect(50, 0, 800, 600))]
        #expect(pairs(h.runMarks([1, 2])) == ["1:/shots/1.png", "2:/shots/2.png"])
        #expect(h.store.discarded.isEmpty)
    }

    @Test func desktopCapturesNeverGroup() {
        h.targets = [1: desktopTarget(), 2: desktopTarget()]
        #expect(pairs(h.runMarks([1, 2])) == ["1:/shots/1.png", "2:/shots/2.png"])
        #expect(h.composited.map(\.numbers) == [[1], [2]])
    }

    @Test func marksHandedOverOutOfOrderStillGroupAndDrawInOrder() {
        h.targets = [1: windowTarget(42), 2: windowTarget(42)]
        #expect(pairs(h.runMarks([1, 2], submitted: [2, 1])) == ["1:/shots/2.png", "2:/shots/2.png"])
        #expect(h.composited.last.map { "\($0.raw) \($0.numbers)" } == "raw1 [1, 2]")
        #expect(h.store.saved.last?.number == 1)  // named after its lowest mark
    }

    @Test func aFailedRecompositeKeepsTheEarlierMarksScreenshot() {
        h.targets = [1: windowTarget(42), 2: windowTarget(42)]
        h.failCompositeOfGroups = true
        #expect(pairs(h.runMarks([1, 2])) == ["1:/shots/1.png"])
        #expect(h.store.discarded.isEmpty)
    }

    @Test func aLateRecompositeLeavesTheFileAlreadyHandedOut() {
        h.targets = [1: windowTarget(42), 2: windowTarget(42)]
        let release = DispatchSemaphore(value: 0)
        h.holdCapture = (2, release)
        let capturer = h.capturer()
        capturer.begin()
        let session = capturer.finish([1, 2].map { arrow((0, 0), (100, 0), $0) })!
        // Mark 2 is still capturing when finalisation gives up waiting.
        #expect(pairs(session.wait(timeout: 0.2)) == ["1:/shots/1.png"])
        release.signal()
        let deadline = Date(timeIntervalSinceNow: 2)
        while h.store.saved.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(h.store.saved.count == 2)
        #expect(h.store.discarded.isEmpty)
    }

    @Test func missingPermissionAsksOnceAndCapturesNothing() {
        h.allowed = false
        let capturer = h.capturer()
        for _ in 0..<2 {
            capturer.begin()
            let stroke = arrow((0, 0), (100, 0))
            capturer.submit(stroke)
            let session = capturer.finish([stroke])!
            #expect(session.wait(timeout: 2).isEmpty)
            #expect(session.permissionMissing)
        }
        #expect(h.requests == 1)
        #expect(h.store.saved.isEmpty)
    }

    @Test func aFailedCaptureIsLoggedAndSkipped() {
        h.failCapture = [1]
        #expect(pairs(h.runMarks([1, 2])) == ["2:/shots/1.png"])
        #expect(h.logs.contains { $0.contains("capture failed") })
    }

    @Test func noSessionMeansNothingIsQueued() {
        let capturer = h.capturer()
        capturer.submit(arrow((0, 0), (100, 0)))
        #expect(capturer.finish([]) == nil)
    }
}

struct DictationMarksTests {
    final class Logs: @unchecked Sendable { var lines: [String] = [] }

    func strokes(_ numbers: [Int] = [1, 2, 3]) -> [Stroke] {
        numbers.map { Stroke(points: pts([(0, 0)]), startedAt: 0, endedAt: 1, number: $0) }
    }

    /// A session whose worker has already settled these paths (nil for a failed mark).
    func session(_ paths: [Int: String?]) -> CaptureSession {
        let session = CaptureSession(ident: 1)
        _ = session.expect(paths.keys.sorted().map { Stroke(points: pts([(0, 0)]), startedAt: 0, endedAt: 1, number: $0) })
        for (number, path) in paths {
            if let path { _ = session.record(path, for: [number]) } else { session.settle(number) }
        }
        return session
    }

    @Test func waitsLongerForMoreMarksAndLogsAnyLeftOut() {
        let logs = Logs()
        let marks = DictationMarks(strokes: strokes(), session: session([1: "/a.png", 2: nil, 3: "/c.png"]), audioOrigin: 0, log: { logs.lines.append($0) })
        #expect(marks.numbers() == [1, 3])
        #expect(marks.imagePaths() == ["/a.png", "/c.png"])
        #expect(logs.lines == ["Mark(s) [2] have no screenshot to paste."])
    }

    @Test func sharedScreenshotsArePastedOnceInOrderOfTheirLowestMark() {
        // Marks 1 and 3 share a window; mark 2 is on another one.
        let marks = DictationMarks(strokes: strokes(), session: session([1: "/one-and-three.png", 2: "/two.png", 3: "/one-and-three.png"]), audioOrigin: 0)
        #expect(marks.numbers() == [1, 2, 3])
        #expect(marks.imagePaths() == ["/one-and-three.png", "/two.png"])
    }

    @Test func withoutASessionThereIsNothingToPaste() {
        let marks = DictationMarks(strokes: strokes(), session: nil, audioOrigin: 0)
        #expect(marks.numbers().isEmpty)
        #expect(marks.imagePaths().isEmpty)
    }

    @Test func theWaitGrowsWithTheNumberOfMarks() {
        // Nothing ever settles, so the wait runs to its end: 4 s plus 1 s a mark.
        let marks = DictationMarks(strokes: strokes([1, 2]), session: CaptureSession(ident: 1), audioOrigin: 0)
        marks.waitTimeout = 0.05
        marks.waitPerMark = 0.05
        let session = marks.session!
        _ = session.expect(strokes([1, 2]))
        let started = Date()
        #expect(marks.numbers().isEmpty)
        #expect(Date().timeIntervalSince(started) >= 0.14)
    }

    @Test func markTimesAreSecondsOfAudio() {
        let strokes = [Stroke(points: pts([(0, 0)]), startedAt: 10.2, endedAt: 10.7, number: 1),
                       Stroke(points: pts([(0, 0)]), startedAt: 12.5, endedAt: 12.7, number: 2)]
        let marks = DictationMarks(strokes: strokes, session: nil, audioOrigin: 10)
        let times = marks.audioTimes([1, 2])
        #expect(abs(times[0] - 0.7) < 1e-9 && abs(times[1] - 2.7) < 1e-9)
    }
}
