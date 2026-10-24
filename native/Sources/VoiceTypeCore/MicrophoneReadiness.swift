import Foundation

/// The check that has to pass before Voice Type takes a dictation, ported from the readiness
/// loop in voice-type.py's hotkey_worker and microphone_readiness.py.
///
/// The preferred microphone (the Yeti) gets 30 seconds to turn up, since after a wake it can
/// take that long to enumerate, and only then does the system default get a go. Whichever
/// one it is gets a 0.35 s probe, which has to deliver real samples: after a wake Core Audio
/// can open a device that only ever delivers zeros, and dictating into that loses the words.
public enum ReadinessTiming {
    public static let preferredWaitSeconds = 30.0
    public static let probeSeconds = 0.35
    public static let retrySeconds = 1.0
    /// After a wake or a broken stream, how long a microphone that's there but delivers
    /// nothing (silence, no samples, a start that fails) is retried before the process
    /// restarts for a fresh Core Audio, as Python did at every wake. Longer than the Yeti's
    /// 30 s, so the system default still gets a go first.
    public static let deadMicrophoneSeconds = 45.0
}

public struct ProbeResult: Equatable, Sendable {
    public var ready: Bool
    public var device: InputDevice
    public var reason: String

    public init(ready: Bool, device: InputDevice, reason: String = "") {
        self.ready = ready
        self.device = device
        self.reason = reason
    }

    /// Why a probe's samples don't count as a live microphone, or nil if they do.
    public static func rejection(for samples: [Float]) -> String? {
        guard !samples.isEmpty else { return "no samples" }
        let levels = AudioLevels(samples: samples)
        if levels.rms <= 0.000001 && levels.peak <= 0.00001 { return "digital silence" }
        return nil
    }
}

public protocol MicrophoneProbing: AnyObject, Sendable {
    /// Opens the device for `selection` for about `seconds`, then closes it. Throws
    /// MicrophoneUnavailable when the device can't be resolved, and CoreAudioHang when one of
    /// its Core Audio calls didn't return in time (the stream is then abandoned, never touched).
    func probe(_ selection: MicrophoneSelection, seconds: Double) throws -> ProbeResult
}

public struct ReadinessOutcome: Equatable, Sendable {
    /// What recordings should use: the preferred microphone by name when it passed, or the
    /// system default, looked up again at each key-down.
    public var selection: MicrophoneSelection
    public var device: InputDevice
}

public enum ReadinessResult: Equatable, Sendable {
    case ready(ReadinessOutcome)
    case cancelled
    /// A probe's Core Audio call hung. Its thread may hold the HAL's lock, so trying again in
    /// this process could hang too: restart.
    case coreAudioHung(String)
    /// A microphone was there but delivered nothing usable for `deadMicrophoneSeconds`.
    case gaveUp(String)
}

public final class MicrophoneReadiness: @unchecked Sendable {
    private let probe: MicrophoneProbing
    private let now: () -> Double
    private let sleep: (Double) -> Void
    private let log: (String) -> Void

    public init(probe: MicrophoneProbing, now: @escaping () -> Double, sleep: @escaping (Double) -> Void, log: @escaping (String) -> Void) {
        self.probe = probe
        self.now = now
        self.sleep = sleep
        self.log = log
    }

    /// The preferred microphone during its grace period, then the system default.
    public static func candidate(preferred: String, elapsed: Double, wait: Double = ReadinessTiming.preferredWaitSeconds) -> String? {
        let name = PythonText.strip(preferred)
        return !name.isEmpty && elapsed < wait ? name : nil
    }

    public static func initialMessage(preferred: String) -> String {
        let name = PythonText.strip(preferred)
        return name.isEmpty ? "Checking the default microphone..." : "Checking for \(name)..."
    }

    /// Blocks until a microphone passes, reporting status messages as it goes, or `cancelled`
    /// turns true. With `giveUpAfter`, a microphone that's present but keeps failing its probe
    /// for that long ends the wait (`gaveUp`); with nil it waits as long as it takes, as
    /// Python's startup did. A missing microphone never counts towards it: plugging it in is
    /// the fix, not a restart.
    public func run(preferred: String, giveUpAfter: Double? = nil, report: (String) -> Void, cancelled: () -> Bool) -> ReadinessResult {
        let name = PythonText.strip(preferred)
        let started = now()
        var lastFailure: String?
        var fallbackAnnounced = false
        var deadSince: Double?
        report(Self.initialMessage(preferred: name))
        while !cancelled() {
            let elapsed = now() - started
            let candidate = Self.candidate(preferred: name, elapsed: elapsed)
            if !name.isEmpty && candidate == nil && !fallbackAnnounced {
                log("Preferred microphone '\(name)' was not ready after \(Int(ReadinessTiming.preferredWaitSeconds))s; trying the system default microphone.")
                fallbackAnnounced = true
            }
            let selection: MicrophoneSelection = candidate.map { .named($0) } ?? .systemDefault
            let failure: String
            do {
                let result = try probe.probe(selection, seconds: ReadinessTiming.probeSeconds)
                if result.ready {
                    log("Microphone ready: '\(result.device.name)'.")
                    return .ready(ReadinessOutcome(selection: selection, device: result.device))
                }
                failure = "\(result.device.name): \(result.reason)"
                deadSince = deadSince ?? now()
            } catch let hang as CoreAudioHang {
                log("Microphone check: \(hang.localizedDescription); Voice Type will restart.")
                return .coreAudioHung(hang.localizedDescription)
            } catch let missing as MicrophoneUnavailable {
                failure = missing.localizedDescription
                deadSince = nil
            } catch {
                // The device is there but Core Audio won't open it, which Python's
                // audio_recovery also took as needing a fresh process.
                failure = error.localizedDescription
                deadSince = deadSince ?? now()
            }
            if failure != lastFailure {
                log("Microphone not ready (\(failure)); Voice Type will not accept dictation yet.")
                lastFailure = failure
            }
            if let giveUpAfter, let deadSince, now() - deadSince >= giveUpAfter {
                log("Microphone still not delivering audio after \(Int(giveUpAfter))s (\(failure)).")
                return .gaveUp(failure)
            }
            if let candidate {
                let remaining = max(1, Int(ReadinessTiming.preferredWaitSeconds - elapsed))
                report("Waiting for \(candidate)... (\(remaining)s)")
            } else {
                report("Waiting for the default microphone...")
            }
            sleep(ReadinessTiming.retrySeconds)
        }
        return .cancelled
    }
}
