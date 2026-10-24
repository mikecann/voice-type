import Foundation
import Testing
@testable import VoiceTypeCore
@testable import VoiceTypeMac

// Only pieces that need no hardware or permissions: nothing here opens a tap, the
// microphone or the pasteboard, or runs launchctl.

struct ResamplerTests {
    func tone(seconds: Double, rate: Double, hz: Double = 440) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    @Test func turns48kHzInto16kHz() {
        let resampler = Resampler(inputRate: 48_000)
        let out = resampler.finish(tone(seconds: 1, rate: 48_000))
        #expect(abs(out.count - 16_000) <= 2)
        // A 440 Hz tone keeps its level.
        let middle = out[2000..<14000]
        let rms = (middle.map { $0 * $0 }.reduce(0, +) / Float(middle.count)).squareRoot()
        #expect(abs(rms - 0.5 / 2.0.squareRoot().float) < 0.01)
    }

    @Test func givesTheSameSamplesHoweverTheBlocksAreSplit() {
        let input = tone(seconds: 2, rate: 48_000, hz: 1000)
        let whole = Resampler(inputRate: 48_000).finish(input)
        let streamed = Resampler(inputRate: 48_000)
        var pieces: [Float] = []
        var i = 0
        // Blocks the size Core Audio delivers, with a ragged one in between.
        for size in [512, 512, 333, 512, 480] + Array(repeating: 512, count: 200) where i < input.count {
            let end = min(i + size, input.count)
            pieces += streamed.process(Array(input[i..<end]))
            i = end
        }
        pieces += streamed.finish(Array(input[i...]))
        #expect(pieces.count == whole.count)
        #expect(zip(pieces, whole).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func startsCleanAfterFinish() {
        let resampler = Resampler(inputRate: 44_100)
        let first = resampler.finish(tone(seconds: 0.5, rate: 44_100))
        let second = resampler.finish(tone(seconds: 0.5, rate: 44_100))
        #expect(first == second)
    }

    @Test func sixteenKilohertzInIsSixteenOut() {
        let input = tone(seconds: 0.25, rate: 16_000)
        let out = Resampler(inputRate: 16_000).finish(input)
        #expect(out.count == input.count)
    }
}

struct SampleRingTests {
    @Test func readsWhatWasWrittenInOrder() {
        let ring = SampleRing(capacity: 8)
        let samples: [Float] = [1, 2, 3, 4, 5]
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) }
        #expect(ring.readAll() == samples)
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) }
        #expect(ring.readAll() == samples)
        #expect(ring.readAll() == [])
    }

    @Test func dropsRatherThanOverwritesWhenFull() {
        let ring = SampleRing(capacity: 4)
        let samples: [Float] = [1, 2, 3]
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3) }
        samples.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 3) }
        #expect(ring.readAll() == [1, 2, 3])
        #expect(ring.takeDropped() == 3)
    }
}

struct LaunchctlParsingTests {
    @Test func readsPrintDisabled() {
        let output = """
        disabled services = {
        \t"com.mikerosoft.voice-type" => disabled
        \t"com.mikerosoft.voice-type-native" => enabled
        \t"com.old.style" => true
        }
        """
        #expect(ProcessLaunchControl.isDisabled("com.mikerosoft.voice-type", inPrintDisabledOutput: output))
        #expect(!ProcessLaunchControl.isDisabled("com.mikerosoft.voice-type-native", inPrintDisabledOutput: output))
        #expect(ProcessLaunchControl.isDisabled("com.old.style", inPrintDisabledOutput: output))
        #expect(!ProcessLaunchControl.isDisabled("com.not.listed", inPrintDisabledOutput: output))
    }
}

struct LaunchctlPrintTests {
    @Test func knowsWhenLaunchdWillBringAJobBack() {
        #expect(ProcessLaunchControl.willRun(inPrintOutput: "\tstate = running\n\tlast exit code = 75\n"))
        // Exited 75: KeepAlive restarts it after the throttle.
        #expect(ProcessLaunchControl.willRun(inPrintOutput: "\tstate = not running\n\tlast exit code = 75\n"))
        // Quit, or a duplicate that exited 0: it stays down.
        #expect(!ProcessLaunchControl.willRun(inPrintOutput: "\tstate = not running\n\tlast exit code = 0\n"))
        #expect(ProcessLaunchControl.willRun(inPrintOutput: "\tstate = not running\n\tlast exit code = (never exited)\n"))
    }
}

private extension Double {
    var float: Float { Float(self) }
}
