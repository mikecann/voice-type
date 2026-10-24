import Foundation
import Testing
@testable import VoiceTypeCore

// Ported from tests/test_screen_marks.py.

func line(_ start: (Double, Double), _ end: (Double, Double), steps: Int = 20) -> [MarkPoint] {
    (0...steps).map { i in
        MarkPoint(start.0 + (end.0 - start.0) * Double(i) / Double(steps), start.1 + (end.1 - start.1) * Double(i) / Double(steps))
    }
}

func circle(_ cx: Double, _ cy: Double, _ r: Double, steps: Int = 36) -> [MarkPoint] {
    (0...steps).map { i in
        MarkPoint(cx + r * cos(2 * .pi * Double(i) / Double(steps)), cy + r * sin(2 * .pi * Double(i) / Double(steps)))
    }
}

func pts(_ list: [(Double, Double)]) -> [MarkPoint] { list.map { MarkPoint($0.0, $0.1) } }

struct ClassifyStrokeTests {
    @Test func aClickWithALittleWobbleIsAPoint() {
        #expect(ScreenMarks.classify(pts([(100, 100), (102, 101), (101, 103)])) == .point)
    }

    @Test func aSingleSampleIsAPoint() {
        #expect(ScreenMarks.classify(pts([(5, 5)])) == .point)
    }

    @Test func aStraightDragIsAnArrow() {
        #expect(ScreenMarks.classify(line((0, 0), (200, 80))) == .arrow)
    }

    @Test func aSlightlyShakyLineIsStillAnArrow() {
        let points = stride(from: 0, to: 200, by: 10).enumerated().map { i, x in MarkPoint(Double(x), 50 + (i % 2 == 1 ? 3 : -3)) }
        #expect(ScreenMarks.classify(points) == .arrow)
    }

    @Test func aCircleStaysFreeform() {
        #expect(ScreenMarks.classify(circle(300, 300, 60)) == .freeform)
    }

    @Test func aShortFlickIsNotAnArrow() {
        #expect(ScreenMarks.classify(line((0, 0), (20, 0))) == .freeform)
    }

    @Test func scrubbingBackAndForthAlongALineIsNotAnArrow() {
        let points = line((0, 0), (200, 0)) + line((200, 0), (40, 0)) + line((40, 0), (200, 0))
        #expect(ScreenMarks.classify(points) == .freeform)
    }

    @Test func anLShapeIsNotAnArrow() {
        #expect(ScreenMarks.classify(line((0, 0), (200, 0)) + line((200, 0), (200, 200))) == .freeform)
    }

    @Test func arrowheadPointsBackFromTheTip() {
        let (tip, left, right) = ScreenMarks.arrowhead(line((0, 0), (200, 0)), length: 18)
        #expect(tip == MarkPoint(200, 0))
        #expect(left.x < 200)
        #expect(right.x < 200)
        #expect(abs(left.y + right.y) < 1e-9)
    }

    @Test func anchorIsTheArrowTipAndTheCircleCentre() {
        let arrow = Stroke(points: line((0, 0), (200, 0)), startedAt: 0, endedAt: 1)
        let ring = Stroke(points: circle(300, 300, 60), startedAt: 0, endedAt: 1)
        let click = Stroke(points: pts([(40, 50)]), startedAt: 0, endedAt: 1)
        #expect(ScreenMarks.anchor(arrow) == MarkPoint(200, 0))
        let centre = ScreenMarks.anchor(ring)
        #expect(abs(centre.x - 300) <= 1 && abs(centre.y - 300) <= 1)
        #expect(ScreenMarks.anchor(click) == MarkPoint(40, 50))
    }

    @Test func arrowBadgeSitsBehindTheTail() {
        let badge = ScreenMarks.badgeCenter(Stroke(points: line((100, 100), (300, 100)), startedAt: 0, endedAt: 1))
        #expect(badge.x < 100)
        #expect(badge.y == 100)
    }
}

func window(_ pid: Int32, _ x: Double, _ y: Double, _ w: Double, _ h: Double, layer: Int = 0, alpha: Double = 1, number: Int = 1) -> WindowInfo {
    WindowInfo(number: number, ownerPID: pid, ownerName: "App\(pid)", layer: layer, alpha: alpha, bounds: MarkRect(x, y, w, h))
}

struct ChooseWindowTests {
    @Test func picksTheFrontmostWindowContainingThePoint() {
        let windows = [window(10, 0, 0, 100, 100, number: 1), window(11, 50, 50, 500, 500, number: 2), window(12, 0, 0, 2000, 2000, number: 3)]
        #expect(ScreenMarks.chooseWindow(windows, at: MarkPoint(200, 200))?.number == 2)
    }

    @Test func skipsOurOwnWindows() {
        let windows = [window(99, 0, 0, 3000, 2000, number: 1), window(11, 0, 0, 800, 600, number: 2)]
        #expect(ScreenMarks.chooseWindow(windows, at: MarkPoint(100, 100), excluding: [99])?.number == 2)
    }

    @Test func skipsMenusTheDockAndInvisibleWindows() {
        let windows = [
            window(1, 0, 0, 800, 600, layer: 25, number: 1),
            window(2, 0, 0, 800, 600, alpha: 0, number: 2),
            window(3, 90, 90, 20, 20, number: 3),  // a tooltip
            window(4, 0, 0, 800, 600, number: 4),
        ]
        #expect(ScreenMarks.chooseWindow(windows, at: MarkPoint(100, 100))?.number == 4)
    }

    @Test func returnsNoneOverBareDesktop() {
        #expect(ScreenMarks.chooseWindow([window(4, 0, 0, 100, 100)], at: MarkPoint(500, 500)) == nil)
    }

    @Test func handlesWindowsOnADisplayLeftOfThePrimary() {
        #expect(ScreenMarks.chooseWindow([window(4, -1920, 100, 1000, 800)], at: MarkPoint(-1500, 300)) != nil)
    }
}

struct MarkCoordinateTests {
    let primaryHeight = 1117.0

    @Test func primaryScreenFlipsToTopLeft() {
        #expect(ScreenMarks.appKitFrameToQuartz(MarkRect(0, 0, 1728, 1117), primaryHeight: primaryHeight) == MarkRect(0, 0, 1728, 1117))
    }

    @Test func aDisplayAboveThePrimaryHasNegativeQuartzY() {
        // AppKit: an external 2560x1440 sitting on top of the laptop screen.
        #expect(ScreenMarks.appKitFrameToQuartz(MarkRect(-400, 1117, 2560, 1440), primaryHeight: primaryHeight) == MarkRect(-400, -1440, 2560, 1440))
    }

    @Test func aDisplayBelowAndLeft() {
        #expect(ScreenMarks.appKitFrameToQuartz(MarkRect(-1920, -1080, 1920, 1080), primaryHeight: primaryHeight) == MarkRect(-1920, 1117, 1920, 1080))
    }

    @Test func viewCoordinatesAreRelativeToTheirScreen() {
        let screen = ScreenMarks.appKitFrameToQuartz(MarkRect(-400, 1117, 2560, 1440), primaryHeight: primaryHeight)
        #expect(ScreenMarks.quartzToView(MarkPoint(100, -1400), screen: screen) == MarkPoint(500, 40))
    }

    @Test func retinaWindowCaptureDoublesOffsets() {
        #expect(ScreenMarks.toImage(MarkPoint(300, 150), capture: MarkRect(200, 100, 800, 600), imageWidth: 1600, imageHeight: 1200) == MarkPoint(200, 100))
    }

    @Test func oneXDisplayKeepsPointsAsPixels() {
        #expect(ScreenMarks.toImage(MarkPoint(-1900, 1147), capture: MarkRect(-1920, 1117, 1920, 1080), imageWidth: 1920, imageHeight: 1080) == MarkPoint(20, 30))
    }

    @Test func longEdgeIsCapped() {
        #expect(ScreenMarks.fitLongEdge(width: 3456, height: 2160) == (1568, 980))
        #expect(ScreenMarks.fitLongEdge(width: 2160, height: 3456) == (980, 1568))
        #expect(ScreenMarks.fitLongEdge(width: 800, height: 600) == (800, 600))
    }

    @Test func displayLookupAndNearestFallback() {
        let displays = [MarkRect(0, 0, 1728, 1117), MarkRect(-1920, 0, 1920, 1080)]
        #expect(ScreenMarks.display(containing: MarkPoint(-10, 10), in: displays) == displays[1])
        #expect(ScreenMarks.display(containing: MarkPoint(2000, 10), in: displays) == displays[0])
        #expect(ScreenMarks.display(containing: MarkPoint(0, 0), in: []) == nil)
    }

    @Test func desktopRegionStaysInsideItsDisplay() {
        #expect(ScreenMarks.desktopRegion(MarkRect(0, 0, 1728, 1117), around: MarkPoint(10, 10)) == MarkRect(0, 0, 800, 800))
        #expect(ScreenMarks.desktopRegion(MarkRect(0, 0, 1728, 1117), around: MarkPoint(1720, 1110)) == MarkRect(928, 317, 800, 800))
        #expect(ScreenMarks.desktopRegion(MarkRect(0, 0, 600, 500), around: MarkPoint(300, 250)) == MarkRect(0, 0, 600, 500))
    }
}

struct InkShapesTests {
    @Test func inkLandsWhereTheMarkWasOnARetinaWindow() {
        let stroke = Stroke(points: line((300, 200), (500, 200)), startedAt: 0, endedAt: 1, number: 3)
        let rect = MarkRect(200, 100, 800, 600)
        let shapes = ScreenMarks.inkShapes(stroke, scale: 2) { ScreenMarks.toImage($0, capture: rect, imageWidth: 1600, imageHeight: 1200) }
        #expect(shapes.kind == .arrow)
        #expect(shapes.line[0] == MarkPoint(200, 200))
        // The line stops under the arrowhead instead of poking past its tip.
        #expect(shapes.line.last!.x < 600 && shapes.line.last!.x > 560)
        #expect(shapes.arrowhead?.0 == MarkPoint(600, 200))
        #expect(shapes.width == ScreenMarks.inkWidth * 2)
        #expect(shapes.number == 3)
        #expect(shapes.badge.center.x < 200)
        #expect(shapes.badge.radius == ScreenMarks.badgeRadius * 2)
    }

    @Test func aClickBecomesARingWithoutALine() {
        let shapes = ScreenMarks.inkShapes(Stroke(points: pts([(10, 10)]), startedAt: 0, endedAt: 1, number: 1))
        #expect(shapes.line.isEmpty)
        #expect(shapes.ring?.center == MarkPoint(10, 10))
        #expect(shapes.ring?.radius == ScreenMarks.ringRadius)
        #expect(shapes.arrowhead == nil)
    }
}

struct MarkerPlacementTests {
    static let words = [
        TimedText(0.0, 0.3, " This"), TimedText(0.3, 0.6, " button"), TimedText(0.6, 0.9, " is"), TimedText(0.9, 1.4, " broken,"),
        TimedText(2.0, 2.3, " and"), TimedText(2.3, 2.6, " this"), TimedText(2.6, 3.0, " one"), TimedText(3.0, 3.4, " too."),
    ]
    static let spoken = words.map(\.text).joined(separator: " ")

    func place(_ text: String, _ times: [Double], words: [TimedText] = words, segments: [TimedText] = [], spoken: String = spoken) -> String {
        let counts = MarkMarkers.spokenWordCounts(times, words: words, segments: segments)
        return MarkMarkers.insertMarkers(text, spoken: spoken, wordCounts: counts, numbers: Array(1...times.count))
    }

    let text = "This button is broken, and this one too."

    @Test func markersFollowTheWordBeingSpoken() {
        #expect(place(text, [0.45, 2.8]) == "This button [1] is broken, and this one [2] too.")
    }

    @Test func markerGoesBeforeTrailingPunctuation() {
        #expect(place(text, [1.6, 5.0]) == "This button is broken [1], and this one too [2].")
    }

    @Test func marksInTheSameSpotShareIt() {
        #expect(place(text, [0.4, 0.5]) == "This button [1] [2] is broken, and this one too.")
    }

    @Test func aMarkBeforeAnySpeechGoesFirst() {
        #expect(place(text, [-0.2]) == "[1] This button is broken, and this one too.")
    }

    @Test func survivesCaseAndPunctuationChanges() {
        #expect(place("This button is broken. And this one, too!", [1.6, 2.8]) == "This button is broken [1]. And this one [2], too!")
    }

    @Test func survivesACorrectionReplacingAWord() {
        let words = [TimedText(0.0, 0.3, " the"), TimedText(0.3, 0.6, " Q"), TimedText(0.6, 0.9, " DA"), TimedText(0.9, 1.2, " build"), TimedText(1.2, 1.5, " fails")]
        let spoken = words.map(\.text).joined(separator: " ")
        #expect(place("the CUDA build fails", [1.0], words: words, spoken: spoken) == "the CUDA build [1] fails")
        // A mark inside the corrected words lands just before them.
        #expect(place("the CUDA build fails", [0.7], words: words, spoken: spoken) == "the [1] CUDA build fails")
    }

    @Test func segmentTimingsUseTheNearestBoundary() {
        let segments = [TimedText(0.0, 1.4, "This button is broken,"), TimedText(2.0, 3.4, "and this one too.")]
        let spoken = segments.map(\.text).joined(separator: " ")
        #expect(place(text, [1.0, 3.1], words: [], segments: segments, spoken: spoken) == "This button is broken [1], and this one too [2].")
        #expect(place(text, [0.3], words: [], segments: segments, spoken: spoken) == "[1] This button is broken, and this one too.")
    }

    @Test func withoutTimingsMarkersAreAppended() {
        #expect(MarkMarkers.spokenWordCounts([1.0], words: [], segments: []) == nil)
        #expect(MarkMarkers.insertMarkers("Look at these.", spoken: "", wordCounts: nil, numbers: [1, 2]) == "Look at these. [1] [2]")
    }

    @Test func noWordsMeansJustMarkers() {
        #expect(MarkMarkers.insertMarkers("", spoken: "", wordCounts: [0, 0], numbers: [1, 2]) == "[1] [2]")
    }

    @Test func noMarksLeavesTheTextAlone() {
        #expect(MarkMarkers.insertMarkers("Hello there.", spoken: "hello there", wordCounts: [], numbers: []) == "Hello there.")
    }

    @Test func alignsLikeDifflib() {
        // difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks() for these.
        let a = ["the", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog"]
        let b = ["a", "quick", "fox", "jumps", "over", "lazy", "dogs", "the", "dog"]
        let blocks = SequenceMatcher(a, b).matchingBlocks().map { [$0.a, $0.b, $0.size] }
        #expect(blocks == [[1, 1, 1], [3, 2, 3], [6, 7, 1], [8, 8, 1], [9, 9, 0]])
    }
}

struct MarkTimingsTests {
    @Test func readsWordAndSegmentTimings() {
        let transcript = Transcript(segments: [
            TranscriptSegment(text: " Hello there", startSec: 0, endSec: 1, noSpeechProb: 0, tokenProbs: [],
                              words: [TimedText(0, 0.4, " Hello"), TimedText(0.5, 1.0, " there")]),
        ])
        let (words, segments) = MarkMarkers.timings(from: transcript)
        #expect(words.map(\.text) == [" Hello", " there"])
        #expect(segments == [TimedText(0, 1, "Hello there")])
    }

    @Test func untimedSegmentsGiveNothing() {
        let transcript = Transcript(segments: [TranscriptSegment(text: "hi", startSec: 0, endSec: 0, noSpeechProb: 0, tokenProbs: [])])
        let (words, segments) = MarkMarkers.timings(from: transcript)
        #expect(words.isEmpty && segments.isEmpty)
        #expect(MarkMarkers.timings(from: nil).words.isEmpty)
    }
}

struct ScreenshotStoreTests {
    @Test func savesAndPrunesOnlyItsOwnExpiredFiles() throws {
        let tmp = try temporaryDirectory("screenshots")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var now = Date(timeIntervalSince1970: 1_790_812_800) // 2026-10-01 UTC
        let dir = tmp.appendingPathComponent("screenshots")
        let store = ScreenshotStore(directory: dir, now: { now })
        let old = try store.save(Data("old png".utf8), number: 1)
        now += 6 * 86_400
        let recent = try store.save(Data("new png".utf8), number: 2)
        let unrelated = dir.appendingPathComponent("keep-me.png")
        try Data("x".utf8).write(to: unrelated)
        now += 2 * 86_400

        #expect(store.cleanup() == 1)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(try Data(contentsOf: URL(fileURLWithPath: recent)) == Data("new png".utf8))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(recent.hasSuffix("_2.png"))
        // The same names as Python's, so either app cleans up after the other.
        let name = URL(fileURLWithPath: recent).lastPathComponent
        #expect(name.range(of: #"^\d{8}T\d{12}Z_[0-9a-f]{32}_\d+\.png$"#, options: .regularExpression) != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: recent)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func discardsItsOwnFilesAndNothingElse() throws {
        let tmp = try temporaryDirectory("screenshots")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("screenshots")
        let store = ScreenshotStore(directory: dir)
        let first = try store.save(Data("one mark".utf8), number: 1)
        let unrelated = dir.appendingPathComponent("keep-me.png")
        try Data("x".utf8).write(to: unrelated)
        let outside = tmp.appendingPathComponent(URL(fileURLWithPath: first).lastPathComponent)
        try Data("x".utf8).write(to: outside)

        #expect(store.discard(first))
        #expect(!FileManager.default.fileExists(atPath: first))
        #expect(!store.discard(first))
        #expect(!store.discard(unrelated.path))
        #expect(!store.discard(outside.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func cleanupWithoutAFolderIsANoOp() throws {
        let tmp = try temporaryDirectory("screenshots")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(ScreenshotStore(directory: tmp.appendingPathComponent("missing")).cleanup() == 0)
    }

    @Test func cleansUpPythonsScreenshotsToo() throws {
        let tmp = try temporaryDirectory("screenshots")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A name screen_marks.ScreenshotStore wrote on 23 October.
        let python = tmp.appendingPathComponent("20261023T005624228899Z_7a7d9b74e710444eadb6f64934a42afc_1.png")
        try Data("x".utf8).write(to: python)
        let store = ScreenshotStore(directory: tmp, now: { Date(timeIntervalSince1970: 1_792_548_000 + 10 * 86_400) })
        #expect(store.cleanup() == 1)
    }
}
