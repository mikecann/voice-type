import Foundation
import Testing
@testable import VoiceTypeCore

// Ported from tests/test_mic_stream.py.
struct MicStreamTests {
    final class Harness {
        var events: [String] = []
        var opened = 0
        var reusable = true
        var failStartOn: Set<Int> = []
        var stopTimesOut = false
        lazy var mic = MicStream(open: { [unowned self] in
            self.opened += 1
            let name = "s\(self.opened)"
            self.events.append("open \(name)")
            let stream = FakeStream(name: name, log: { [unowned self] in self.events.append($0) })
            stream.failStart = self.failStartOn.contains(self.opened)
            return MicStream.Opened(stream: stream, deviceName: "Yeti", reusable: self.reusable)
        }, runBounded: { [unowned self] work in
            if self.stopTimesOut { return false }
            work()
            return true
        })
    }

    @Test func prepareOpensWithoutStarting() throws {
        let h = Harness()
        try h.mic.prepare()
        #expect(h.events == ["open s1"])
        #expect(!h.mic.isRunning)
    }

    @Test func startReusesThePreparedStream() throws {
        let h = Harness()
        try h.mic.prepare()
        #expect(try h.mic.start())
        #expect(h.events == ["open s1", "start s1"])
    }

    @Test func stopKeepsTheStreamForTheNextRecording() throws {
        let h = Harness()
        try h.mic.prepare()
        try h.mic.start()
        h.mic.stop()
        try h.mic.prepare()
        try h.mic.start()
        #expect(h.opened == 1)
        #expect(h.events.suffix(2) == ["stop s1", "start s1"])
    }

    @Test func startWithoutPrepareOpensOnDemand() throws {
        let h = Harness()
        #expect(try !h.mic.start())
        #expect(h.events == ["open s1", "start s1"])
    }

    @Test func invalidateReopensOnTheNextPrepare() throws {
        let h = Harness()
        try h.mic.prepare()
        h.mic.invalidate()
        try h.mic.prepare()
        #expect(h.events == ["open s1", "stop s1", "close s1", "open s2"])
    }

    @Test func anAudioErrorReopensOnTheNextStart() throws {
        let h = Harness()
        try h.mic.prepare()
        try h.mic.start()
        h.mic.noteError()
        h.mic.stop()
        #expect(try !h.mic.start())
        #expect(h.opened == 2)
    }

    @Test func aStreamOnAFallbackDeviceIsNotReused() throws {
        let h = Harness()
        h.reusable = false
        try h.mic.prepare()
        #expect(try !h.mic.start())
        h.mic.stop()
        try h.mic.prepare()
        #expect(try !h.mic.start())
        #expect(h.opened == 3)
    }

    @Test func prepareDoesNotTouchARunningRecording() throws {
        let h = Harness()
        try h.mic.start()
        h.mic.invalidate()
        try h.mic.prepare()
        #expect(h.opened == 1)
        #expect(h.mic.isRunning)
    }

    @Test func aFailedStartOnAPreparedStreamRetriesWithAFreshOne() throws {
        let h = Harness()
        h.failStartOn = [1]
        try h.mic.prepare()
        #expect(try !h.mic.start())
        #expect(h.opened == 2)
        #expect(h.events.last == "start s2")
        #expect(h.mic.isRunning)
    }

    @Test func aFailedStartOnAFreshStreamThrowsAndClosesIt() throws {
        let h = Harness()
        h.failStartOn = [1]
        #expect(throws: MicrophoneUnavailable.self) { try h.mic.start() }
        #expect(!h.mic.isRunning)
        #expect(h.events.last == "close s1")
    }

    @Test func aTimedOutStopDropsTheStream() throws {
        let h = Harness()
        try h.mic.prepare()
        try h.mic.start()
        h.stopTimesOut = true
        #expect(!h.mic.stop())
        #expect(!h.mic.isRunning)
        h.stopTimesOut = false
        try h.mic.start()
        #expect(h.opened == 2)
    }

    @Test func theDeviceNameSurvivesStop() throws {
        let h = Harness()
        try h.mic.start()
        h.mic.stop()
        #expect(h.mic.deviceName == "Yeti")
    }
}

// Ported from tests/test_recording_session.py.
struct CaptureBufferTests {
    @Test func aFailedStartClearsTheLastRecordingsAudio() {
        let buffer = CaptureBuffer()
        buffer.markStarted()
        buffer.append([1, 2])
        buffer.resetForStartAttempt()
        buffer.append([3])
        #expect(!buffer.hasAudio)
        #expect(buffer.stop() == [])
    }

    @Test func stoppedAudioIsHandedOverExactlyOnce() {
        let buffer = CaptureBuffer()
        buffer.markStarted()
        #expect(buffer.append([1, 2]))
        #expect(!buffer.append([3]))
        #expect(buffer.stop() == [1, 2, 3])
        #expect(buffer.stop() == [])
    }

    @Test func blocksAfterStopAreDropped() {
        let buffer = CaptureBuffer()
        buffer.markStarted()
        _ = buffer.stop()
        #expect(!buffer.append([1]))
        #expect(!buffer.hasAudio)
    }
}

// Ported from tests/test_microphone_readiness.py.
struct ReadinessTests {
    let yeti = InputDevice(id: 2, name: "Yeti Stereo Microphone")
    let laptop = InputDevice(id: 1, name: "MacBook Pro Microphone")

    @Test func resolvesTheConfiguredMicrophoneInsteadOfTheDefault() throws {
        let catalog = FakeCatalog([laptop, yeti], default: laptop)
        #expect(try DeviceResolver.resolve(.named("yeti stereo microphone"), in: catalog) == yeti)
        #expect(try DeviceResolver.resolve(.systemDefault, in: catalog) == laptop)
    }

    @Test func aMissingConfiguredMicrophoneIsNotReplacedByTheDefault() {
        let catalog = FakeCatalog([laptop], default: laptop)
        #expect(throws: MicrophoneUnavailable("Configured microphone 'Yeti Stereo Microphone' is not available")) {
            try DeviceResolver.resolve(.named("Yeti Stereo Microphone"), in: catalog)
        }
    }

    @Test func twoDevicesWithTheSameNameCountAsUnavailable() {
        let catalog = FakeCatalog([yeti, InputDevice(id: 9, name: "Yeti Stereo Microphone")])
        #expect(throws: MicrophoneUnavailable.self) { try DeviceResolver.resolve(.named("Yeti Stereo Microphone"), in: catalog) }
    }

    @Test func thePreferredMicrophoneGetsItsGracePeriodThenTheDefault() {
        #expect(MicrophoneReadiness.candidate(preferred: "Yeti", elapsed: 29.9) == "Yeti")
        #expect(MicrophoneReadiness.candidate(preferred: "Yeti", elapsed: 30) == nil)
        #expect(MicrophoneReadiness.candidate(preferred: "  ", elapsed: 0) == nil)
    }

    @Test func theProbeRejectsDigitalSilence() {
        #expect(ProbeResult.rejection(for: []) == "no samples")
        #expect(ProbeResult.rejection(for: [Float](repeating: 0, count: 5600)) == "digital silence")
        #expect(ProbeResult.rejection(for: (0..<5600).map { Float($0 % 3) * 0.0005 }) == nil)
    }

    @Test func statusMessagesMatchPythons() {
        #expect(MicrophoneReadiness.initialMessage(preferred: "Yeti Stereo Microphone") == "Checking for Yeti Stereo Microphone...")
        #expect(MicrophoneReadiness.initialMessage(preferred: "") == "Checking the default microphone...")
    }

    @Test func countsDownWhileWaitingForTheYeti() {
        let clock = ManualExecutor()
        let catalog = FakeCatalog([laptop], default: laptop)
        var reports: [String] = []
        let readiness = MicrophoneReadiness(probe: FakeProbe(catalog: catalog), now: { clock.now }, sleep: { clock.sleep($0) }, log: { _ in })
        let outcome = readiness.run(preferred: "Yeti Stereo Microphone", report: { reports.append($0) }, cancelled: { false })
        #expect(outcome == .ready(ReadinessOutcome(selection: .systemDefault, device: laptop)))
        #expect(reports.first == "Checking for Yeti Stereo Microphone...")
        #expect(reports[1] == "Waiting for Yeti Stereo Microphone... (30s)")
        #expect(reports.last == "Waiting for Yeti Stereo Microphone... (1s)")
    }

    @Test func stopsWhenCancelled() {
        let readiness = MicrophoneReadiness(probe: FakeProbe(catalog: FakeCatalog([])), now: { 0 }, sleep: { _ in }, log: { _ in })
        var calls = 0
        #expect(readiness.run(preferred: "", report: { _ in }, cancelled: { calls += 1; return calls > 3 }) == .cancelled)
    }

    @Test func aHungProbeEndsTheWaitStraightAway() {
        let clock = ManualExecutor()
        let probe = FakeProbe(catalog: FakeCatalog([laptop]))
        probe.hangs = true
        let readiness = MicrophoneReadiness(probe: probe, now: { clock.now }, sleep: { clock.sleep($0) }, log: { _ in })
        let result = readiness.run(preferred: "", report: { _ in }, cancelled: { false })
        #expect(result == .coreAudioHung(CoreAudioHang("starting the probe").localizedDescription))
        // No second try, which could hang on the same HAL lock.
        #expect(probe.probed.count == 1)
    }

    @Test func aMicrophoneThatNeverDeliversGivesUpOnlyWhenAsked() {
        let clock = ManualExecutor()
        let probe = FakeProbe(catalog: FakeCatalog([laptop]))
        probe.silentProbes = 1000
        let readiness = MicrophoneReadiness(probe: probe, now: { clock.now }, sleep: { clock.sleep($0) }, log: { _ in })
        let result = readiness.run(preferred: "", giveUpAfter: ReadinessTiming.deadMicrophoneSeconds, report: { _ in }, cancelled: { false })
        #expect(result == .gaveUp("MacBook Pro Microphone: digital silence"))
        #expect(clock.now >= 45 && clock.now < 47)
        // Without a limit (startup, as in Python) it keeps waiting.
        var calls = 0
        #expect(readiness.run(preferred: "", report: { _ in }, cancelled: { calls += 1; return calls > 100 }) == .cancelled)
    }

    @Test func aMissingMicrophoneNeverCountsAsDead() {
        let clock = ManualExecutor()
        let readiness = MicrophoneReadiness(probe: FakeProbe(catalog: FakeCatalog([], default: nil)), now: { clock.now }, sleep: { clock.sleep($0) }, log: { _ in })
        var calls = 0
        #expect(readiness.run(preferred: "", giveUpAfter: 45, report: { _ in }, cancelled: { calls += 1; return calls > 100 }) == .cancelled)
        #expect(clock.now > 90)
    }
}

// Ported from tests/test_platform_mac_clipboard.py.
final class FakePasteboard: Pasteboard {
    var items: [PasteboardItemSnapshot]
    var changeCount = 0
    var lazyText: String?
    var onRead: (() -> Void)?
    var refuse = false
    /// What macOS lets the copy-out see, as GeneralPasteboard classifies it.
    var readability = PasteboardSnapshot.Readability.complete

    init(_ items: [PasteboardItemSnapshot]) { self.items = items }

    func snapshot() -> PasteboardSnapshot {
        // A refused read sees the types but none of the data.
        PasteboardSnapshot(items: readability == .complete ? items : items.map { _ in [] }, readability: readability)
    }

    func restore(_ saved: [PasteboardItemSnapshot]) {
        changeCount += 1
        items = saved
    }

    func offerLazily(_ text: String, onRead: @escaping @Sendable () -> Void) -> Bool {
        guard !refuse else { return false }
        changeCount += 1
        items = []
        lazyText = text
        self.onRead = onRead
        return true
    }

    func placeText(_ text: String) {
        changeCount += 1
        lazyText = nil
        lazyData = nil
        items = [[("public.utf8-plain-text", Data(text.utf8))]]
    }

    var lazyData: (data: Data, type: String)?

    func offerLazily(data: Data, type: String, onRead: @escaping @Sendable () -> Void) -> Bool {
        guard !refuse else { return false }
        changeCount += 1
        items = []
        lazyText = nil
        lazyData = (data, type)
        self.onRead = onRead
        return true
    }

    func placeData(_ data: Data, type: String) {
        changeCount += 1
        lazyText = nil
        lazyData = nil
        items = [[(type, data)]]
    }

    /// The target app reading the lazy item.
    func read() {
        if let lazyText {
            items = [[("public.utf8-plain-text", Data(lazyText.utf8))]]
        } else if let lazyData {
            items = [[(lazyData.type, lazyData.data)]]
        } else {
            return
        }
        onRead?()
    }

    func copyNewer(_ text: String) {
        changeCount += 1
        lazyText = nil
        lazyData = nil
        items = [[("public.utf8-plain-text", Data(text.utf8))]]
    }

    var texts: [String] { items.flatMap { $0.map { String(decoding: $0.data, as: UTF8.self) } } }
}

final class FakePasteEnvironment: PasteEnvironment {
    var onCommandV: () -> Void = {}
    var front: Int32? = 42
    var focusReadings: [FocusReading] = [FocusReading(.editable, role: "AXTextArea")]
    var activations: [TargetApp] = []
    var sounds = 0
    var focusCalls = 0

    func postCommandV() { onCommandV() }
    func frontmostPID() -> Int32? { front }
    func focus(inApp pid: Int32?) -> FocusReading {
        focusCalls += 1
        return focusReadings.count > 1 ? focusReadings.removeFirst() : focusReadings[0]
    }
    func activate(_ app: TargetApp) -> Bool {
        activations.append(app)
        front = app.pid
        return true
    }
    func playFailureSound() { sounds += 1 }
}

struct PasterTests {
    let old: [PasteboardItemSnapshot] = [[("public.png", Data("PNG".utf8)), ("public.tiff", Data("TIFF".utf8))], [("public.utf8-plain-text", Data("caption".utf8))]]

    func paster(_ board: FakePasteboard, _ env: FakePasteEnvironment, clock: ManualExecutor = ManualExecutor()) -> Paster {
        Paster(pasteboard: board, environment: env, now: { clock.now }, sleep: { clock.sleep($0) }, log: { _ in }, readTimeout: 0.05)
    }

    @Test func restoresEveryItemAndTypeAfterTheTargetReads() throws {
        let board = FakePasteboard(old)
        let env = FakePasteEnvironment()
        env.onCommandV = { board.read() }
        let outcome = try paster(board, env).paste("dictated words", into: TargetApp(pid: 42, name: "T3"))
        #expect(outcome.landed)
        #expect(outcome.readLatency != nil)
        #expect(board.items.map { $0.map(\.type) } == [["public.png", "public.tiff"], ["public.utf8-plain-text"]])
        #expect(board.texts == ["PNG", "TIFF", "caption"])
        #expect(env.sounds == 0)
    }

    @Test func anEmptyClipboardStaysEmpty() throws {
        let board = FakePasteboard([])
        let env = FakePasteEnvironment()
        env.onCommandV = { board.read() }
        _ = try paster(board, env).paste("voice", into: nil)
        #expect(board.items.isEmpty)
    }

    @Test func keepsTheTextWhenTheTargetNeverReadsIt() throws {
        let board = FakePasteboard(old)
        let env = FakePasteEnvironment()
        let outcome = try paster(board, env).paste("dictated words", into: nil)
        #expect(!outcome.landed)
        #expect(outcome.readLatency == nil)
        #expect(env.focusCalls == 0)
        #expect(board.texts == ["dictated words"])
        #expect(env.sounds == 1)
    }

    @Test func keepsTheTextWhenNoTextBoxHadFocus() throws {
        let board = FakePasteboard(old)
        let env = FakePasteEnvironment()
        env.onCommandV = { board.read() }
        env.focusReadings = [FocusReading(.notEditable, role: "AXWebArea")]
        let outcome = try paster(board, env).paste("dictated words", into: nil)
        #expect(!outcome.landed)
        #expect(outcome.focusRole == "AXWebArea")
        #expect(board.texts == ["dictated words"])
        #expect(env.focusCalls > 1)
    }

    @Test func neverRestoresOverSomethingCopiedAfterThePaste() throws {
        let board = FakePasteboard(old)
        let env = FakePasteEnvironment()
        env.onCommandV = {
            board.read()
            board.copyNewer("newer copy")
        }
        _ = try paster(board, env).paste("dictated words", into: nil)
        #expect(board.texts == ["newer copy"])
    }

    @Test func aMissedPasteDoesNotOverwriteSomethingCopiedSince() throws {
        let board = FakePasteboard(old)
        let env = FakePasteEnvironment()
        env.onCommandV = {
            board.read()
            board.copyNewer("newer copy")
        }
        env.focusReadings = [FocusReading(.notEditable, role: "AXGroup")]
        let outcome = try paster(board, env).paste("dictated words", into: nil)
        #expect(!outcome.landed)
        #expect(board.texts == ["newer copy"])
    }

    @Test func aDeniedReadIsNeverPutBackSoTheTextStaysInsteadOfAnEmptyClipboard() throws {
        let board = FakePasteboard(old)
        board.readability = .denied
        let env = FakePasteEnvironment()
        env.onCommandV = { board.read() }
        let outcome = try paster(board, env).paste("dictated words", into: nil)
        #expect(outcome.landed)
        #expect(outcome.clipboard == .denied)
        // Not wiped: the words are there to paste again.
        #expect(board.texts == ["dictated words"])
    }

    @Test func anIncompleteReadIsNotPutBackEither() throws {
        let board = FakePasteboard(old)
        board.readability = .incomplete
        let env = FakePasteEnvironment()
        env.onCommandV = { board.read() }
        _ = try paster(board, env).paste("dictated words", into: nil)
        #expect(board.texts == ["dictated words"])
    }

    @Test func classifiesWhatACopyOutIsWorth() {
        let png: PasteboardItemSnapshot = [("public.png", Data("PNG".utf8))]
        // Everything read.
        #expect(PasteboardSnapshot.classify(items: [png], typesPerItem: [1], typesOnBoard: 1, access: "default") == .complete)
        // One lazy representation gone: the rest still comes back, as in Python.
        #expect(PasteboardSnapshot.classify(items: [png], typesPerItem: [2], typesOnBoard: 2, access: "default") == .complete)
        // Denied in settings, or Don't Allow on the prompt: types visible, no data.
        #expect(PasteboardSnapshot.classify(items: [png], typesPerItem: [1], typesOnBoard: 1, access: "always_deny") == .denied)
        #expect(PasteboardSnapshot.classify(items: [[], []], typesPerItem: [2, 1], typesOnBoard: 3, access: "ask") == .denied)
        #expect(PasteboardSnapshot.classify(items: [], typesPerItem: [], typesOnBoard: 2, access: "default") == .denied)
        // One whole item unreadable.
        #expect(PasteboardSnapshot.classify(items: [png, []], typesPerItem: [1, 1], typesOnBoard: 2, access: "default") == .incomplete)
        // Empty: trusted only when reads are always allowed.
        #expect(PasteboardSnapshot.classify(items: [], typesPerItem: [], typesOnBoard: 0, access: "always_allow") == .complete)
        #expect(PasteboardSnapshot.classify(items: [], typesPerItem: [], typesOnBoard: 0, access: "ask") == .incomplete)
    }

    @Test func aRefusedPasteboardIsAnError() {
        let board = FakePasteboard(old)
        board.refuse = true
        #expect(throws: PasteError.self) { try paster(board, FakePasteEnvironment()).paste("x", into: nil) }
    }

    @Test func refocusesOnlyWhenAnotherAppIsInFront() throws {
        let board = FakePasteboard([])
        let env = FakePasteEnvironment()
        env.onCommandV = { board.read() }
        let p = paster(board, env)
        #expect(try !p.paste("a", into: TargetApp(pid: 42, name: "T3")).refocused)
        env.front = 7
        #expect(try p.paste("b", into: TargetApp(pid: 42, name: "T3")).refocused)
        env.front = nil
        #expect(try p.paste("c", into: TargetApp(pid: 42, name: "T3")).refocused)
        #expect(try !p.paste("d", into: nil).refocused)
        #expect(env.activations.count == 2)
    }

    @Test func classifiesFocusLikePython() {
        for role in ["AXTextArea", "AXTextField", "AXComboBox"] {
            #expect(FocusReading.classify(role: role, valueSettable: false) == .editable)
        }
        #expect(FocusReading.classify(role: "AXGroup", valueSettable: true) == .editable)
        for role in ["AXWebArea", "AXGroup", "AXButton"] {
            #expect(FocusReading.classify(role: role, valueSettable: false) == .notEditable)
        }
        #expect(FocusReading.classify(role: nil, valueSettable: false) == .unknown)
    }

    @Test func waitsForAnAppToMoveThePasteIntoItsTextBox() {
        let env = FakePasteEnvironment()
        env.focusReadings = [FocusReading(.notEditable, role: "AXWebArea"), FocusReading(.notEditable, role: "AXWebArea"), FocusReading(.editable, role: "AXTextArea")]
        let (ok, role) = paster(FakePasteboard([]), env).waitForTextBox(pid: 42)
        #expect(ok && role == "AXTextArea")
    }

    @Test func trustsThePasteWhenAccessibilityCannotTell() {
        let env = FakePasteEnvironment()
        env.focusReadings = [FocusReading(.unknown)]
        let (ok, role) = paster(FakePasteboard([]), env).waitForTextBox(pid: 42)
        #expect(ok && role == nil)
        #expect(env.focusCalls == 1)
    }
}

// Ported from tests/test_platform_mac_hotkeys.py.
struct HotkeyStateTests {
    @Test func onlyRightControlActivatesPushToTalk() {
        var keys = HotkeyState()
        let r1 = keys.handle(.flagsChanged, keycode: 0x3B, flags: 0x40101)
        #expect(!r1)  // Left Control
        #expect(!keys.isDown)
        let r2 = keys.handle(.flagsChanged, keycode: HotkeyState.rightControl, flags: 0x42100)
        #expect(r2)
        #expect(keys.isDown)
        let r3 = keys.handle(.flagsChanged, keycode: HotkeyState.rightControl, flags: 0x100)
        #expect(r3)
        #expect(!keys.isDown)
    }

    @Test func f12StaysActiveWhenRightControlIsReleased() {
        var keys = HotkeyState()
        _ = keys.handle(.keyDown, keycode: HotkeyState.f12, flags: 0)
        _ = keys.handle(.flagsChanged, keycode: HotkeyState.rightControl, flags: 0x2000)
        _ = keys.handle(.flagsChanged, keycode: HotkeyState.rightControl, flags: 0)
        #expect(keys.isDown)
        _ = keys.handle(.keyUp, keycode: HotkeyState.f12, flags: 0)
        #expect(!keys.isDown)
    }

    @Test func otherKeysPassThrough() {
        var keys = HotkeyState()
        let r4 = keys.handle(.keyDown, keycode: 9, flags: 0)
        #expect(!r4)  // V
        let r5 = keys.handle(.flagsChanged, keycode: HotkeyState.f12, flags: 0)
        #expect(!r5)
        let r6 = keys.handle(.keyDown, keycode: HotkeyState.rightControl, flags: 0)
        #expect(!r6)
    }

    @Test func passesTheKeysThroughWhileNotSwallowingAndKeepsEachPressesChoice() {
        var keys = HotkeyState()
        #expect(keys.handle(.keyDown, keycode: HotkeyState.f12, flags: 0, swallowing: false) == .passThrough)
        #expect(keys.isDown)
        // Swallowing comes back on mid-press: the release still goes through with its press.
        #expect(keys.handle(.keyDown, keycode: HotkeyState.f12, flags: 0, swallowing: true) == .passThrough)
        #expect(keys.handle(.keyUp, keycode: HotkeyState.f12, flags: 0, swallowing: true) == .passThrough)
        #expect(keys.handle(.flagsChanged, keycode: HotkeyState.rightControl, flags: 0x2000, swallowing: true) == .swallow)
        #expect(keys.handle(.flagsChanged, keycode: HotkeyState.rightControl, flags: 0, swallowing: false) == .swallow)
        #expect(keys.handle(.keyDown, keycode: 9, flags: 0, swallowing: true) == .notOurs)
    }

    @Test func aReleaseWhosePressWasNeverSeenGoesThrough() {
        var keys = HotkeyState()
        #expect(keys.handle(.keyUp, keycode: HotkeyState.f12, flags: 0, swallowing: true) == .passThrough)
        #expect(!keys.isDown)
    }

    @Test func resetForgetsEveryKey() {
        var keys = HotkeyState()
        _ = keys.handle(.keyDown, keycode: HotkeyState.f12, flags: 0)
        keys.reset()
        #expect(!keys.isDown)
    }
}

// Ported from tests/test_preview_format.py.
struct PreviewFormatTests {
    @Test func keepsShortTextUnchanged() { #expect(PreviewFormat.wrap("hello there") == "hello there") }

    @Test func wrapsToTwoLines() {
        #expect(PreviewFormat.wrap("one two three four five six seven eight", maxChars: 20) == "one two three four\nfive six seven eight")
    }

    @Test func keepsTheLastTwoLinesWithALeadingEllipsis() {
        #expect(PreviewFormat.wrap("one two three four five six seven eight nine ten", maxChars: 20) == "\u{2026}five six seven eight\nnine ten")
    }

    @Test func previewTextJoinsLikeThePythonLoop() {
        let t = Transcript(segments: [" A. ", "", " B "].map { TranscriptSegment(text: $0, startSec: 0, endSec: 0, noSpeechProb: 0, tokenProbs: []) })
        #expect(PreviewFormat.previewText(t) == "A.  B")
    }
}

// Ported from tests/test_overlay_feedback.py.
struct PillTests {
    final class Surface: PillSurface {
        var presented: [PillAppearance] = []
        var hidden = 0
        var alpha = 1.0
        var progress: Double??
        func present(_ appearance: PillAppearance, repositionOnly: Bool) { presented.append(appearance) }
        func hide() { hidden += 1 }
        func setAlpha(_ alpha: Double) { self.alpha = alpha }
        func setBarHeights(_ heights: [Double], color: PillColor) {}
        func setCheckProgress(_ progress: Double?) { self.progress = .some(progress) }
    }

    func make(reduceMotion: Bool = false) -> (PillController, Surface, ManualExecutor) {
        let surface = Surface()
        let clock = ManualExecutor()
        return (PillController(surface: surface, scheduler: clock, now: { clock.now }, reduceMotion: { reduceMotion }), surface, clock)
    }

    @Test func successHoldsThenFadesAndHides() {
        let (pill, surface, clock) = make()
        pill.showDone(words: 1)
        #expect(surface.presented.last == PillAppearance(state: .done, text: "1 word"))
        #expect(surface.presented.last?.label == " 1 word")
        #expect(surface.presented.last?.color == .green)
        clock.advance(0.21)
        #expect(pill.isVisible)
        // The hold ends at 0.22 s and the first fade frame comes 16 ms later.
        clock.advance(0.03)
        #expect(pill.isVisible && surface.alpha < 1)
        clock.advance(0.2)
        #expect(!pill.isVisible)
    }

    @Test func aNewRecordingCancelsTheHoldAndRestoresOpacity() {
        let (pill, surface, clock) = make()
        pill.showDone(words: 42)
        clock.advance(0.3)
        pill.showRecording()
        clock.advance(1)
        #expect(pill.state == .rec && pill.isVisible)
        #expect(surface.alpha == 1)
        #expect(surface.presented.last?.label == " REC")
    }

    @Test func reducedMotionHidesAfterTheHoldWithoutAFade() {
        let (pill, surface, clock) = make(reduceMotion: true)
        pill.showDone(words: 2)
        #expect(surface.progress == .some(1))
        clock.advance(0.22)
        #expect(!pill.isVisible)
    }

    @Test func failureHasALongerHoldAndTheClipboardHint() {
        let (pill, surface, clock) = make()
        pill.showPasteFailed()
        #expect(surface.presented.last?.label == " Clipboard")
        #expect(surface.presented.last?.preview == "On your clipboard. \u{2318}V to paste")
        #expect(surface.presented.last?.wideLabel == true)
        clock.advance(1.59)
        #expect(pill.isVisible)
        clock.advance(0.02)
        #expect(!pill.isVisible)
    }

    @Test func theClipboardNoticeHoldsLongerAndSaysHowToFixIt() {
        let (pill, surface, clock) = make()
        pill.showClipboardNotKept()
        #expect(surface.presented.last?.label == " Pasted")
        #expect(surface.presented.last?.preview == "Allow Paste from other apps to keep your clipboard")
        #expect(surface.presented.last?.color == .orange)
        clock.advance(3.9)
        #expect(pill.isVisible)
        clock.advance(0.2)
        #expect(!pill.isVisible)
    }

    @Test func wordCountsArePlural() {
        #expect(PillAppearance(state: .done, text: "3 words").label == " 3 words")
        let (pill, surface, _) = make()
        pill.showDone(words: 3)
        #expect(surface.presented.last?.label == " 3 words")
    }

    @Test func recordingKeepsItsNarrowLabel() {
        #expect(!PillAppearance(state: .rec, text: "").wideLabel)
        #expect(PillAppearance(state: .processing, text: "x").label == " ...")
        #expect(PillAppearance(state: .processing, text: "x").preview == "x")
    }

    @Test func drawsTheShortStrokeBeforeTheLongOneAndClamps() {
        #expect(PillController.checkmarkPoints(-1) == [12, 12, 12, 12, 12, 12])
        #expect(PillController.checkmarkPoints(1.0 / 3) == [12, 12, 20, 20, 20, 20])
        #expect(PillController.checkmarkPoints(2) == [12, 12, 20, 20, 36, 4])
    }
}

// Ported from tests/test_operation_watchdog.py.
struct WatchdogTests {
    @Test func aCompletedOperationDoesNotTimeOut() async throws {
        let fired = AbortFlag()
        let watchdog = OperationWatchdog(name: "t", timeout: 0.05) { fired.set() }
        watchdog.start()
        watchdog.complete()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(!fired.isSet)
    }

    @Test func aBlockedOperationTimesOutExactlyOnce() async throws {
        let count = Counter()
        let watchdog = OperationWatchdog(name: "t", timeout: 0.05) { count.increment() }
        watchdog.start()
        watchdog.start()
        // Waits for the timer rather than a fixed time: on a heavily loaded Mac (load
        // average over 300) a 0.05 s timer once took more than 0.2 s to fire.
        let deadline = Date(timeIntervalSinceNow: 30)
        while count.value == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(count.value == 1)
        // Then long enough for a second timer from the second start() to have fired too.
        try await Task.sleep(nanoseconds: 300_000_000)
        watchdog.complete()
        #expect(count.value == 1)
    }

    @Test func theFinalisationDeadlineScalesWithLength() {
        #expect(Deadlines.finalisation(durationSec: 2) == 30)
        #expect(Deadlines.finalisation(durationSec: 60) == 120)
        #expect(Deadlines.finalisation(durationSec: 2, marks: 0) == 30)
    }

    @Test func screenMarksAddTheirOwnWaitsToTheFinalisationDeadline() {
        // A 3 s clip with ten marks: the screenshots (4 s + 1 s a mark), the timing pass
        // (4.3 s), and ten pastes of up to 0.35 + 2 + 0.05 s, plus the last gap.
        let budget = Deadlines.finalisation(durationSec: 3, marks: 10)
        #expect(abs(budget - (30 + 14 + 4.3 + 10 * 2.4 + 0.35)) < 1e-9)
        // Each part is bounded on its own, so the sum always fits inside the deadline.
        let worst = DictationMarks.captureWait + 10 * DictationMarks.captureWaitPerMark + Deadlines.wordTiming(durationSec: 3)
            + 10 * (Paster.imageGap + Paster.readTimeout + Paster.providerHandOver) + Paster.imageGap
        #expect(budget >= 30 + worst)
        #expect(Deadlines.finalisation(durationSec: 60, marks: 1) > Deadlines.finalisation(durationSec: 60))
    }

    @Test func boundedWorkTimesOutWithoutWaiting() {
        let started = Date()
        #expect(!BoundedRunner.run(timeout: 0.05, name: "t") { Thread.sleep(forTimeInterval: 0.5) })
        #expect(Date().timeIntervalSince(started) < 0.4)
        #expect(BoundedRunner.run(timeout: 1, name: "t") {})
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.withLock { n } }
        func increment() { lock.withLock { n += 1 } }
    }
}

struct InstanceLockTests {
    @Test func onlyOneHolderAtATimeAndThePIDIsWritten() throws {
        let dir = try temporaryDirectory("lock")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice-type.instance.lock")
        let first = InstanceLock(url: url)
        let second = InstanceLock(url: url)
        #expect(first.tryAcquire(pid: 1234))
        #expect(!second.tryAcquire())
        #expect(second.recordedPID() == 1234)
        first.release()
        #expect(second.tryAcquire(pid: 99))
        #expect(second.recordedPID() == 99)
    }

    @Test func tellsNativeFromAnythingElse() {
        #expect(LockHolder.identify(pid: 5, executablePath: { _ in "/Users/x/Applications/Voice Type Native.app/Contents/MacOS/voice-type-native" }) == .native(pid: 5))
        // The pid has been reused by something else since.
        #expect(LockHolder.identify(pid: 5, executablePath: { _ in "/usr/bin/vim" }) == .other(pid: 5))
        #expect(LockHolder.identify(pid: 5, executablePath: { _ in nil }) == .other(pid: 5))
        #expect(LockHolder.identify(pid: nil) == .other(pid: nil))
    }
}

final class FakeLaunchControl: LaunchControl {
    let native = LaunchAgents.nativeLabel
    var loaded: Set<String>
    var disabled: Set<String>
    var calls: [String] = []

    init(loaded: Set<String>, disabled: Set<String>) {
        self.loaded = loaded
        self.disabled = disabled
    }

    func isLoaded(_ label: String) -> Bool { loaded.contains(label) }
    func isDisabled(_ label: String) -> Bool { disabled.contains(label) }
    func enable(_ label: String) throws { calls.append("enable \(label)"); disabled.remove(label) }
    func bootstrap(_ plist: URL) throws {
        let label = plist.deletingPathExtension().lastPathComponent
        calls.append("bootstrap \(label)")
        loaded.insert(label)
    }
    func kickstart(_ label: String, restart: Bool) throws { calls.append("kickstart\(restart ? " -k" : "") \(label)") }
}

struct LaunchAgentTests {
    let native = LaunchAgents.nativeLabel
    var plist: URL { URL(fileURLWithPath: "/LA/\(native).plist") }

    @Test func startingAnAgentThatIsNotLoadedBootstrapsIt() throws {
        let launch = FakeLaunchControl(loaded: [], disabled: [])
        try LaunchAgents.start(launch, plist: plist, checkPlist: { _, _ in nil })
        #expect(launch.calls == ["bootstrap \(native)"])
        #expect(launch.loaded == [native])
    }

    @Test func aLoadedAgentIsKickstartedNotBootstrapped() throws {
        // Quit from the menu: still loaded, just not running.
        let launch = FakeLaunchControl(loaded: [native], disabled: [])
        try LaunchAgents.start(launch, plist: plist, checkPlist: { _, _ in nil })
        #expect(launch.calls == ["kickstart \(native)"])
    }

    @Test func aDisabledAgentIsEnabledFirstSoItStartsAtLoginAgain() throws {
        // How an older build's `switch python` left it.
        let launch = FakeLaunchControl(loaded: [native], disabled: [native])
        try LaunchAgents.start(launch, plist: plist, checkPlist: { _, _ in nil })
        #expect(launch.calls == ["enable \(native)", "kickstart \(native)"])
        #expect(launch.disabled.isEmpty)
    }

    @Test func aBrokenPlistIsReportedBeforeBootstrap() {
        let launch = FakeLaunchControl(loaded: [], disabled: [])
        #expect(throws: LaunchctlError("/LA/x.plist isn't a valid property list. Run native/scripts/build-app.sh to install it again.")) {
            try LaunchAgents.start(launch, plist: plist, checkPlist: { _, _ in "/LA/x.plist isn't a valid property list" })
        }
        #expect(launch.calls.isEmpty)
    }

    @Test func theNativeAgentIsAValidPlist() throws {
        let text = LaunchAgents.nativePlistContents(executable: "/Users/x/Applications/Voice Type Native.app/Contents/MacOS/voice-type-native",
                                                    logDirectory: URL(fileURLWithPath: "/Users/x/Library/Logs/Voice Type"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == native)
        #expect(plist["ProgramArguments"] as? [String] == ["/Users/x/Applications/Voice Type Native.app/Contents/MacOS/voice-type-native"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect(plist["StandardErrorPath"] as? String == "/Users/x/Library/Logs/Voice Type/native-launchd.log")
    }

    @Test func checksAnAgentBeforeRelyingOnIt() throws {
        let dir = try temporaryDirectory("agents")
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.plist")
        try Data(LaunchAgents.nativePlistContents(executable: "/bin/sh").utf8).write(to: good)
        #expect(LaunchAgentCheck.problem(with: good, label: native) == nil)
        #expect(LaunchAgentCheck.problem(with: good, label: "com.example.other") == "\(good.path) isn't the agent for com.example.other")
        let gone = dir.appendingPathComponent("gone.plist")
        try Data(LaunchAgents.nativePlistContents(executable: "/nowhere/voice-type-native").utf8).write(to: gone)
        #expect(LaunchAgentCheck.problem(with: gone, label: native) == "\(gone.path) runs /nowhere/voice-type-native, which isn't there")
        let broken = dir.appendingPathComponent("broken.plist")
        try Data("<plist><dict><key>Label".utf8).write(to: broken)
        #expect(LaunchAgentCheck.problem(with: broken, label: native) == "\(broken.path) isn't a valid property list")
        #expect(LaunchAgentCheck.problem(with: dir.appendingPathComponent("none.plist"), label: native) == "\(dir.appendingPathComponent("none.plist").path) is missing")
    }
}

struct NativeStatusTests {
    @Test func roundTripsAndKnowsWhenItIsReadyOrBusy() throws {
        let dir = try temporaryDirectory("status")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("native-status.json")
        var status = NativeStatus(pid: 77, state: "idle", modelStatus: "ready", hotkeyListener: "event-tap", holdsLock: true)
        try status.write(to: url)
        #expect(NativeStatus.read(from: url) == status)
        #expect(status.isReady && !status.isBusy)
        status.state = "finalising"
        try status.write(to: url)
        #expect(NativeStatus.read(from: url)?.isBusy == true)
        // The key keeps its old name, so the file's format doesn't change.
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"holds_python_lock\" : true"))
        status.holdsLock = false
        #expect(!status.isReady)
    }

    @Test func readsAFileAnOlderBuildWrote() throws {
        let dir = try temporaryDirectory("status")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("native-status.json")
        // Written by a build that could still switch to Python: its handover_failure is ignored.
        try Data("""
        {"enabled": true, "finalize_in_flight": false, "handover_failure": {"at": 1000, "message": "no Python agent"},
         "holds_python_lock": true, "hotkey_listener": "event-tap", "message": "", "microphone": "Yeti", "model_status": "ready",
         "pasteboard_access": "default", "permissions": {}, "pid": 77, "preferred_microphone": "", "state": "idle",
         "updated_at": "2026-10-24T09:00:00+00:00", "version": "0.1.0"}
        """.utf8).write(to: url)
        let status = try #require(NativeStatus.read(from: url))
        #expect(status.pid == 77 && status.isReady)
    }
}

struct LogFileTests {
    @Test func rotatesPastAMegabyteKeepingTheLastLines() throws {
        let dir = try temporaryDirectory("log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice-type-native.log")
        try Data((1...300).map { "line \($0)" }.joined(separator: "\n").appending("\n").utf8).write(to: url)
        let log = LogFile(url: url, echoToStderr: false, maxBytes: 100, keepLines: 2)
        log.log("hello")
        log.flush()
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
        #expect(lines[0] == "[log rotated \u{2014} kept last 2 of 300 lines]")
        #expect(lines[1] == "line 299" && lines[2] == "line 300")
        #expect(lines[3].hasSuffix("  hello"))
    }

    @Test func rotatesWhileRunningToo() throws {
        let dir = try temporaryDirectory("log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice-type-native.log")
        let log = LogFile(url: url, echoToStderr: false, maxBytes: 2_000, keepLines: 5)
        for i in 1...200 { log.log("line \(i) of a long-running app") }
        log.flush()
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(text.utf8.count < 4_000)
        #expect(text.contains("[log rotated \u{2014} kept last 5 of"))
        #expect(text.hasSuffix("line 200 of a long-running app\n"))
        // Still writing after the rotation.
        log.log("after")
        log.flush()
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).hasSuffix("  after\n"))
    }

    @Test func trimsLaunchdsLogInPlaceSoItsOpenFileCarriesOn() throws {
        let dir = try temporaryDirectory("log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("native-launchd.log")
        try Data((1...300).map { "launchd \($0)" }.joined(separator: "\n").appending("\n").utf8).write(to: url)
        // What launchd holds: a descriptor opened for appending.
        let launchd = try FileHandle(forWritingTo: url)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        LogFile.trimInPlace(url, maxBytes: 100, keepLines: 3)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int == inode)
        _ = try launchd.seekToEnd()
        launchd.write(Data("crash report\n".utf8))
        try launchd.close()
        let lines = String(decoding: try Data(contentsOf: url), as: UTF8.self).split(separator: "\n")
        #expect(lines == ["[log rotated \u{2014} kept last 3 of 300 lines]", "launchd 298", "launchd 299", "launchd 300", "crash report"])
    }
}

struct InferenceWorkerTests {
    final class SlowEngine: DictationEngine, @unchecked Sendable {
        let lock = NSLock()
        var order: [String] = []
        let previewStarted = DispatchSemaphore(value: 0)

        func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
            try transcribe(samples, options: options, abort: nil)
        }

        func transcribe(_ samples: [Float], options: TranscribeOptions, abort: AbortFlag?) throws -> Transcript {
            let kind = abort == nil ? "final" : "preview"
            lock.withLock { order.append("\(kind) \(samples.count)") }
            if let abort {
                previewStarted.signal()
                // Like whisper.cpp checking its abort callback between steps.
                for _ in 0..<200 where !abort.isSet { Thread.sleep(forTimeInterval: 0.005) }
            }
            return Transcript(segments: [TranscriptSegment(text: kind, startSec: 0, endSec: 0, noSpeechProb: 0, tokenProbs: [])])
        }

        func promptTokens(for prompt: String?) -> [Int32] { [] }
    }

    @Test func keyUpAbortsTheRunningPreviewAndTheFinalGoesNext() throws {
        let engine = SlowEngine()
        let worker = InferenceWorker(makeEngine: { engine })
        let loaded = DispatchSemaphore(value: 0)
        worker.load { _ in loaded.signal() }
        loaded.wait()
        #expect(worker.modelState == .ready)

        let previewDone = DispatchSemaphore(value: 0)
        let result = ResultBox()
        worker.preview([Float](repeating: 0, count: 10), prompt: nil) { result.value = $0; previewDone.signal() }
        engine.previewStarted.wait()
        let started = Date()
        worker.beginFinal()
        // No new previews between key-up and the final pass.
        worker.preview([Float](repeating: 0, count: 20), prompt: nil) { _ in }
        let final = try worker.run { engine, _ in try engine.transcribe([1, 2, 3], options: TranscribeOptions()) }
        #expect(Date().timeIntervalSince(started) < 0.5)
        previewDone.wait()
        #expect(result.value == nil)
        #expect(final.text == "final")
        #expect(engine.lock.withLock { engine.order } == ["preview 10", "final 3"])
        worker.endFinal()
    }

    @Test func aNewerPreviewReplacesOneThatHasNotStarted() throws {
        let engine = SlowEngine()
        let worker = InferenceWorker(makeEngine: { engine })
        // Not loaded yet, so previews just wait.
        let first = ResultBox()
        worker.preview([0], prompt: nil) { first.value = $0; first.called = true }
        worker.preview([0, 0], prompt: nil) { _ in }
        #expect(first.called && first.value == nil)
    }

    final class ResultBox: @unchecked Sendable {
        var value: Transcript?
        var called = false
    }
}

struct WordTimingWorkerTests {
    final class TimingEngine: DictationEngine, @unchecked Sendable {
        let lock = NSLock()
        var calls: [TranscribeOptions] = []
        func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
            try transcribe(samples, options: options, abort: nil)
        }
        func transcribe(_ samples: [Float], options: TranscribeOptions, abort: AbortFlag?) throws -> Transcript {
            lock.withLock { calls.append(options) }
            return Transcript(segments: [TranscriptSegment(text: " timed", startSec: 0, endSec: 1, noSpeechProb: 0, tokenProbs: [],
                                                           words: [TimedText(0.2, 0.6, " timed")])])
        }
        func promptTokens(for prompt: String?) -> [Int32] { prompt == nil ? [] : [7, 8] }
    }

    final class Loads: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var logs: [String] = []
    }

    func worker(_ timing: TimingEngine?, loads: Loads, fail: Bool = false, idle: Double = 300) -> InferenceWorker {
        let main = TimingEngine()
        let worker = InferenceWorker(makeEngine: { main }, makeTimingEngine: timing.map { engine in
            {
                loads.lock.withLock { loads.count += 1 }
                if fail { throw MicrophoneUnavailable("no DTW for you") }
                return engine
            }
        }, timingIdleSeconds: idle, log: { line in loads.lock.withLock { loads.logs.append(line) } })
        let loaded = DispatchSemaphore(value: 0)
        worker.load { _ in loaded.signal() }
        loaded.wait()
        return worker
    }

    @Test func aMarkLoadsTheTimingEngineOnceAndKeyUpUsesIt() {
        let timing = TimingEngine(), loads = Loads()
        let worker = worker(timing, loads: loads)
        #expect(!worker.timingEngineLoaded)
        worker.prepareWordTimings()
        worker.prepareWordTimings()
        #expect(worker.timingEngineLoaded)
        let transcript = worker.startWordTimings([0, 0, 0], promptTokens: [7, 8], timeout: 5).wait()
        #expect(transcript?.segments.first?.words == [TimedText(0.2, 0.6, " timed")])
        #expect(loads.count == 1)
        // Word timings asked for, with the final pass's word list tokens.
        #expect(timing.calls.map(\.wordTimings) == [true])
        #expect(timing.calls.map(\.promptTokens) == [[7, 8]])
    }

    @Test func withoutATimingEngineThereAreNoTimings() {
        let worker = worker(nil, loads: Loads())
        worker.prepareWordTimings()
        #expect(worker.startWordTimings([0], promptTokens: [], timeout: 5).wait() == nil)
    }

    @Test func aTimingEngineThatWontLoadIsTriedOnce() {
        let loads = Loads()
        let worker = worker(TimingEngine(), loads: loads, fail: true)
        #expect(worker.startWordTimings([0], promptTokens: [], timeout: 5).wait() == nil)
        #expect(worker.startWordTimings([0], promptTokens: [], timeout: 5).wait() == nil)
        #expect(loads.count == 1)
        #expect(loads.logs.contains { $0.hasPrefix("The word timing model failed to load") })
    }

    @Test func theTimingEngineIsFreedWhenIdle() {
        let loads = Loads()
        let worker = worker(TimingEngine(), loads: loads, idle: 0.05)
        _ = worker.startWordTimings([0], promptTokens: [], timeout: 5).wait()
        let deadline = Date(timeIntervalSinceNow: 5)
        while worker.timingEngineLoaded && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(!worker.timingEngineLoaded)
        // And it comes back for the next dictation with marks.
        #expect(worker.startWordTimings([0], promptTokens: [], timeout: 5).wait() != nil)
        #expect(loads.count == 2)
    }

    final class Timers: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [@Sendable () -> Void] = []
        func add(_ fire: @escaping @Sendable () -> Void) { lock.withLock { pending.append(fire) } }
        var count: Int { lock.withLock { pending.count } }
        func fire(_ index: Int) { lock.withLock { pending[index] }() }
    }

    @Test func eachMarkRestartsTheIdleCountdown() {
        // Loaded by one dictation's pass, then a mark in the next: the countdown runs from
        // the mark, so the context can't be freed between it and key-up.
        let loads = Loads(), timers = Timers()
        let worker = InferenceWorker(makeEngine: { TimingEngine() }, makeTimingEngine: {
            loads.lock.withLock { loads.count += 1 }
            return TimingEngine()
        }, idleTimer: { _, fire in timers.add(fire) })
        let loaded = DispatchSemaphore(value: 0)
        worker.load { _ in loaded.signal() }
        loaded.wait()
        _ = worker.startWordTimings([0], promptTokens: [], timeout: 5).wait()
        // A barrier: the timing thread has finished the pass and set its countdown.
        _ = worker.timingEngineLoaded
        let fromPass = timers.count
        worker.prepareWordTimings()
        #expect(worker.timingEngineLoaded)
        #expect(timers.count == fromPass + 1)
        // The countdowns from before the mark run out: still loaded.
        for i in 0..<fromPass { timers.fire(i) }
        #expect(worker.timingEngineLoaded)
        // The mark's runs out: freed.
        timers.fire(fromPass)
        #expect(!worker.timingEngineLoaded)
        #expect(loads.count == 1)
    }

    @Test func aWakeDropsTheTimingEngineAndTheNextMarkLoadsAFreshOne() {
        let loads = Loads()
        let worker = worker(TimingEngine(), loads: loads)
        worker.prepareWordTimings()
        #expect(worker.timingEngineLoaded)
        worker.dropWordTimings(reason: "wake")
        #expect(!worker.timingEngineLoaded)
        #expect(loads.logs.contains("Word timing model unloaded (wake); the next mark loads it again."))
        worker.prepareWordTimings()
        #expect(worker.timingEngineLoaded)
        #expect(loads.count == 2)
    }

    @Test func aWakeBeforeAnyMarkStartsNothing() {
        let loads = Loads()
        let worker = worker(TimingEngine(), loads: loads)
        worker.dropWordTimings(reason: "wake")
        #expect(!worker.timingEngineLoaded)
        #expect(loads.count == 0)
    }

    /// A timing engine whose passes block until the test lets them go, like one stuck in
    /// Metal after a wake.
    final class StuckEngine: DictationEngine, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
            try transcribe(samples, options: options, abort: nil)
        }
        func transcribe(_ samples: [Float], options: TranscribeOptions, abort: AbortFlag?) throws -> Transcript {
            // Doesn't look at `abort`: a real hang wouldn't either.
            release.wait()
            return Transcript(segments: [])
        }
        func promptTokens(for prompt: String?) -> [Int32] { [] }
    }

    @Test func aHungTimingPassRunsOutOfTimeAndLaterPassesDontQueueBehindIt() {
        let stuck = StuckEngine(), loads = Loads()
        let worker = InferenceWorker(makeEngine: { TimingEngine() }, makeTimingEngine: { stuck },
                                     log: { line in loads.lock.withLock { loads.logs.append(line) } })
        let loaded = DispatchSemaphore(value: 0)
        worker.load { _ in loaded.signal() }
        loaded.wait()
        let started = Date()
        let pass = worker.startWordTimings([0], promptTokens: [], timeout: 0.2)
        #expect(pass.wait() == nil)
        #expect(pass.timedOut)
        #expect(pass.abort.isSet)
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(worker.timingPassStuck)
        // The next dictation gets token timestamps at once instead of waiting again.
        let next = Date()
        #expect(worker.startWordTimings([0], promptTokens: [], timeout: 5).wait() == nil)
        #expect(Date().timeIntervalSince(next) < 1)
        #expect(loads.logs.contains("The last word timing pass is still running; placing markers with the final pass's token timestamps."))
        // The main engine is untouched: a final pass still runs straight away.
        let final = try? worker.run { engine, _ in try engine.transcribe([1], options: TranscribeOptions()) }
        #expect(final?.text == "timed")
        // Once the stuck pass comes back, timing passes work again.
        stuck.release.signal()
        let deadline = Date(timeIntervalSinceNow: 10)
        while worker.timingPassStuck && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!worker.timingPassStuck)
        let again = worker.startWordTimings([0], promptTokens: [], timeout: 10)
        stuck.release.signal()
        #expect(again.wait() != nil)
    }

    @Test func aSlowTimingLoadNeverHoldsUpTheFinalPass() {
        // The timing context loads on its own thread: a final pass doesn't queue behind it.
        let gate = DispatchSemaphore(value: 0), loading = DispatchSemaphore(value: 0)
        let worker = InferenceWorker(makeEngine: { TimingEngine() }, makeTimingEngine: {
            loading.signal()
            gate.wait()
            return TimingEngine()
        })
        let loaded = DispatchSemaphore(value: 0)
        worker.load { _ in loaded.signal() }
        loaded.wait()
        worker.prepareWordTimings()
        loading.wait()
        let started = Date()
        let final = try? worker.run { engine, _ in try engine.transcribe([1], options: TranscribeOptions()) }
        #expect(final?.text == "timed")
        #expect(Date().timeIntervalSince(started) < 5)
        // A pass that times out waiting for the load gives nil, and the load carries on.
        #expect(worker.startWordTimings([0], promptTokens: [], timeout: 0.1).wait() == nil)
        gate.signal()
        #expect(worker.timingEngineLoaded)
    }

    @Test func theTimingThreadWaitsForAFinalPassToFinish() {
        // So the two never share the GPU at key-up.
        let order = Order()
        let inFinal = DispatchSemaphore(value: 0), finishFinal = DispatchSemaphore(value: 0)
        let worker = InferenceWorker(makeEngine: { TimingEngine() }, makeTimingEngine: {
            order.add("timing load")
            return TimingEngine()
        })
        let loaded = DispatchSemaphore(value: 0)
        worker.load { _ in loaded.signal() }
        loaded.wait()
        let finalDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? worker.run { _, _ in
                inFinal.signal()
                finishFinal.wait()
                order.add("final")
            }
            finalDone.signal()
        }
        inFinal.wait()
        worker.prepareWordTimings()
        Thread.sleep(forTimeInterval: 0.1)
        finishFinal.signal()
        finalDone.wait()
        #expect(worker.timingEngineLoaded)
        #expect(order.items == ["final", "timing load"])
    }

    final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var items_: [String] = []
        func add(_ item: String) { lock.withLock { items_.append(item) } }
        var items: [String] { lock.withLock { items_ } }
    }

    @Test func aPassThatIsNotNeededIsDroppedBeforeItRuns() {
        let timing = TimingEngine(), loads = Loads()
        let worker = worker(timing, loads: loads)
        let inFinal = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0), finalDone = DispatchSemaphore(value: 0)
        // A final pass holds the timing thread back, so the pass is still queued when it's
        // cancelled (every capture failed).
        DispatchQueue.global().async {
            _ = try? worker.run { _, _ in
                inFinal.signal()
                gate.wait()
            }
            finalDone.signal()
        }
        inFinal.wait()
        let pass = worker.startWordTimings([0], promptTokens: [], timeout: 5)
        pass.cancel()
        gate.signal()
        finalDone.wait()
        #expect(pass.wait() == nil)
        // Neither loaded nor run.
        #expect(!worker.timingEngineLoaded)
        #expect(loads.count == 0)
        #expect(timing.lock.withLock { timing.calls.isEmpty })
    }
}
