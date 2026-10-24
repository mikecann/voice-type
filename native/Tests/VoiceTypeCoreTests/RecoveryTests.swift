import Foundation
import Testing
@testable import VoiceTypeCore

struct RestartBackoffTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func failures(_ agoSeconds: [Double]) -> [RestartHistory.Entry] {
        agoSeconds.map { RestartHistory.Entry(at: now.timeIntervalSince1970 - $0, reason: "Final model failed to load") }
    }

    @Test func theFirstRestartIsImmediateThenItWaitsLongerThenStops() {
        #expect(RestartBackoff.plan([], now: now) == .startNow)
        #expect(RestartBackoff.plan(failures([10]), now: now) == .startNow)
        #expect(RestartBackoff.plan(failures([30, 10]), now: now) == .wait(seconds: 20))
        #expect(RestartBackoff.plan(failures([60, 40, 10]), now: now) == .wait(seconds: 110))
        #expect(RestartBackoff.plan(failures([200, 100, 50, 10]), now: now) == .wait(seconds: 290))
        #expect(RestartBackoff.plan(failures([500, 200, 100, 50, 10]), now: now) == .giveUp)
        // A wait that has already passed since the last failure starts straight away.
        #expect(RestartBackoff.plan(failures([100, 40]), now: now) == .startNow)
    }

    @Test func saysWhatHappenedAndWhatToDo() {
        let recent = failures([500, 200, 100, 50, 10])
        #expect(RestartBackoff.message(.giveUp, recent: recent) == "Stopped after 5 restarts in 30 min: Final model failed to load. Fix that, then choose Try Again.")
        #expect(RestartBackoff.message(.wait(seconds: 19.2), recent: failures([30, 10])) == "Restarted 2 times in 30 min; trying again in 20s. Last: Final model failed to load")
    }

    @Test func theHistoryKeepsOnlyTheWindowAndClears() throws {
        let dir = try temporaryDirectory("restarts")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = RestartHistory(url: dir.appendingPathComponent("native-restarts.json"))
        #expect(history.recent(now: now).isEmpty)
        history.record("old", now: now.addingTimeInterval(-3600))
        history.record("a", now: now.addingTimeInterval(-60))
        history.record("b", now: now)
        #expect(history.recent(now: now).map(\.reason) == ["a", "b"])
        history.clear()
        #expect(history.recent(now: now).isEmpty)
    }
}

struct StallDetectorTests {
    final class Pings {
        var pending: [() -> Void] = []
        var stalls: [Double] = []
    }

    @Test func firesOnceWhenAPingIsNotAnswered() {
        let clock = ManualExecutor()
        let pings = Pings()
        let detector = StallDetector(timeout: 30, now: { clock.now }, ping: { pings.pending.append($0) }, onStall: { pings.stalls.append($0) })
        detector.check()
        #expect(pings.pending.count == 1)
        // Answered: the next check sends a new one.
        pings.pending.removeFirst()()
        clock.sleep(5)
        detector.check()
        #expect(pings.pending.count == 1)
        // Now the queue is stuck.
        for _ in 0..<6 {
            clock.sleep(5)
            detector.check()
        }
        #expect(pings.stalls.isEmpty)
        clock.sleep(5)
        detector.check()
        detector.check()
        #expect(pings.stalls == [35])
    }
}

struct LockPolicyTests {
    func situation(supervised: Bool = false, relaunched: Bool = false, installed: Bool = true,
                   holder: LockHolder = .nobody, alive: Bool = false) -> LockPolicy.Situation {
        LockPolicy.Situation(supervised: supervised, relaunched: relaunched, nativeAgentInstalled: installed,
                             holder: holder, holderAlive: alive, ownPID: 99)
    }

    @Test func aCopyOpenedByHandStartsLaunchdsCopyInstead() {
        #expect(LockPolicy.plan(situation()) == .startAgentAndQuit)
        // Whatever pid an older process left in the file.
        #expect(LockPolicy.plan(situation(holder: .other(pid: 10), alive: true)) == .startAgentAndQuit)
        #expect(LockPolicy.plan(situation(holder: .native(pid: 5))) == .startAgentAndQuit)
    }

    @Test func aCopyOpenedByHandWhileAnotherRunsQuits() {
        #expect(LockPolicy.plan(situation(holder: .native(pid: 5), alive: true)) == .quit("Voice Type Native is already running (pid 5); quitting this copy."))
        #expect(LockPolicy.plan(situation(installed: false, holder: .native(pid: 5), alive: true)) == .quit("Voice Type Native is already running (pid 5); quitting this copy."))
    }

    @Test func launchdsCopyTakesTheLockUnlessAnotherCopyHasIt() {
        #expect(LockPolicy.plan(situation(supervised: true)) == .take)
        #expect(LockPolicy.plan(situation(supervised: true, holder: .other(pid: 10), alive: true)) == .take)
        // It never quits (KeepAlive wouldn't bring it back after 0), so it waits.
        guard case .wait = LockPolicy.plan(situation(supervised: true, holder: .native(pid: 5), alive: true)) else {
            Issue.record("should wait for the other native copy")
            return
        }
        // Its own pid, left from before: nothing to wait for.
        #expect(LockPolicy.plan(situation(supervised: true, holder: .native(pid: 99), alive: true)) == .take)
    }

    @Test func withoutAnAgentInstalledAHandOpenedCopyDictates() {
        #expect(LockPolicy.plan(situation(installed: false)) == .take)
        guard case .wait = LockPolicy.plan(situation(relaunched: true, holder: .native(pid: 5), alive: true)) else {
            Issue.record("a relaunch waits for the copy it replaced")
            return
        }
    }
}

struct ProcessCheckTests {
    @Test func aStatusFilePidIsOnlyNativeIfItsExecutableIs() {
        let app = "/Users/x/Applications/Voice Type Native.app/Contents/MacOS/voice-type-native"
        #expect(ProcessLookup.isVoiceTypeNative(pid: 4242, executablePath: { _ in app }))
        // The pid now belongs to something else.
        #expect(!ProcessLookup.isVoiceTypeNative(pid: 4242, executablePath: { _ in "/usr/bin/vim" }))
        #expect(!ProcessLookup.isVoiceTypeNative(pid: 4242, executablePath: { _ in nil }))
        #expect(!ProcessLookup.isVoiceTypeNative(pid: getpid(), executablePath: { _ in app }))
    }
}
