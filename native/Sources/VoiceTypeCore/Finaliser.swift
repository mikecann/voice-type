import Foundation

/// The speech engine as the controller and finaliser use it. InferenceWorker is the real one.
public protocol Transcribing: AnyObject, Sendable {
    var modelState: InferenceWorker.ModelState { get }
    func load(completion: @escaping (Result<Void, Error>) -> Void)
    func run<T>(_ body: @escaping (DictationEngine, (String?) -> [Int32]) throws -> T) throws -> T
    func preview(_ samples: [Float], prompt: String?, completion: @escaping (Transcript?) -> Void)
    func beginFinal()
    func endFinal()
}

extension InferenceWorker: Transcribing {}

/// The pill as the controller drives it, from any thread. The app's version hops to the main
/// thread and calls PillController.
public protocol PillPresenting: AnyObject, Sendable {
    func showRecording(_ preview: String)
    func showProcessing(_ preview: String)
    func showDone(words: Int)
    func showPasteFailed()
    /// The paste landed, but the old clipboard couldn't be read, so it wasn't put back.
    func showClipboardNotKept()
    func hide()
}

public protocol Pasting: AnyObject, Sendable {
    func paste(_ text: String, into target: TargetApp?) throws -> PasteOutcome
}

extension Paster: Pasting {}

/// A raised `ModelFileMissing` means there's nothing to load yet, as opposed to a load that
/// failed, so the app waits for the model instead of restarting over and over.
public struct ModelFileMissing: LocalizedError {
    public let path: String
    public init(path: String) { self.path = path }
    public var errorDescription: String? { "no speech model at \(path)" }
}

public extension AudioGate {
    /// Native reconnects the microphone in-process instead of restarting.
    static let nativeFlatlineRecordingMessage = "No microphone audio\nRelease to reconnect"
    static let nativeFlatlineRecoveryMessage = "No microphone audio\nReconnecting the microphone..."
}

/// One dictation after key-up.
public struct FinaliseJob: Sendable {
    public var samples: [Float]
    /// The recording's JSON fields, in Python's order, plus native's.
    public var metadata: [(key: String, value: JSONValue)]
    /// The last live preview, already wrapped, shown while the final pass runs.
    public var preview: String
    public var target: TargetApp?
    public var settings: SettingsFile
    /// When the key went up, on the monotonic clock, and how long stopping the microphone took.
    public var keyUpAt: Double
    public var stopAudioSeconds: Double
    /// How long the key was held. Held this long with no audio at all, the stream is broken.
    public var keyHoldSeconds: Double

    public init(samples: [Float], metadata: [(key: String, value: JSONValue)], preview: String, target: TargetApp?,
                settings: SettingsFile, keyUpAt: Double, stopAudioSeconds: Double, keyHoldSeconds: Double = 0) {
        self.samples = samples
        self.metadata = metadata
        self.preview = preview
        self.target = target
        self.settings = settings
        self.keyUpAt = keyUpAt
        self.stopAudioSeconds = stopAudioSeconds
        self.keyHoldSeconds = keyHoldSeconds
    }
}

public struct FinaliseOutcome: Equatable, Sendable {
    public var status: String
    public var durationSec: Double
    public var words: Int
    /// Whether the paste landed; nil when nothing was pasted.
    public var landed: Bool?
    public var flatline: Bool
}

/// Everything from key-up to the pill's tick, in voice-type.py's order, so no dictation is
/// lost or typed twice: the audio is saved before Whisper runs (even clips the gates drop),
/// the text goes into the history before it's pasted, and nothing is ever retried. Ported
/// from _run_archived_finalization, _finish_dictation, _finish_one_shot and transcribe().
public final class Finaliser: @unchecked Sendable {
    public static let mode = "final_only"

    private let transcriber: Transcribing
    private let pill: PillPresenting
    private let paster: Pasting
    private let archive: RecordingArchive
    private let history: TranscriptionHistory
    private let log: (String) -> Void
    private let now: () -> Double
    /// The clipboard notice shows once per run; after that the log and the permissions
    /// window carry it. Only touched on the finalise lane.
    private var toldAboutClipboard = false

    public init(transcriber: Transcribing, pill: PillPresenting, paster: Pasting, archive: RecordingArchive,
                history: TranscriptionHistory, log: @escaping (String) -> Void, now: @escaping () -> Double) {
        self.transcriber = transcriber
        self.pill = pill
        self.paster = paster
        self.archive = archive
        self.history = history
        self.log = log
        self.now = now
    }

    public func run(_ job: FinaliseJob) -> FinaliseOutcome {
        let levels = AudioLevels(samples: job.samples)
        var outcome = FinaliseOutcome(status: "captured", durationSec: levels.durationSec, words: 0, landed: nil, flatline: false)
        var recordingID: String?
        if job.settings.audioRecordingEnabled {
            do {
                recordingID = try archive.save(job.samples, sampleRate: sampleRate, metadata: job.metadata)
                log("Saved dictation audio: \(recordingID!)")
            } catch {
                // A full or unavailable disk mustn't stop the dictation.
                log("Recording audio save failed: \(error.localizedDescription)")
            }
        }
        func update(_ fields: [(key: String, value: JSONValue)]) {
            if let status = fields.first(where: { $0.key == "status" })?.value.stringValue { outcome.status = status }
            guard let recordingID else { return }
            do { try archive.update(recordingID, fields) } catch { log("Recording metadata update failed: \(error.localizedDescription)") }
        }

        var timings: [(key: String, value: JSONValue)] = [("stop_audio_seconds", .double(job.stopAudioSeconds))]
        do {
            let gated = DictationPipeline.gate(levels)?.status
            // After a wake the AUHAL can start without error and never call back. Zero samples
            // look like a 0 s clip, which the flatline check (0.5 s minimum) misses and the
            // short-clip gate would quietly skip, so the key hold is what counts here.
            let noAudio = AudioGate.isMissingAudio(sampleCount: job.samples.count, keyHoldSeconds: job.keyHoldSeconds)
            if noAudio || gated == .flatlineCapture {
                update([("status", .string("flatline_capture"))])
                outcome.flatline = true
                pill.showProcessing(AudioGate.nativeFlatlineRecoveryMessage)
                if noAudio {
                    log(String(format: "No microphone audio arrived during a %.2fs key hold; skipping transcription and reconnecting the microphone.", job.keyHoldSeconds))
                } else {
                    log(String(format: "Detected flatline microphone capture; skipping transcription and reconnecting the microphone: %.2fs rms=%.6f peak=%.6f",
                               levels.durationSec, levels.rms, levels.peak))
                }
                return outcome
            }
            if gated == .skippedLowLevel {
                update([("status", .string("skipped_low_level"))])
                pill.hide()
                log(String(format: "Skipped near-silent clip: %.2fs rms=%.4f peak=%.4f", levels.durationSec, levels.rms, levels.peak))
                return outcome
            }

            // The last preview stays up while the final pass runs.
            pill.showProcessing(job.preview)
            let started = now()
            log("Finalize mode: '\(Self.mode)'")
            var text = ""
            var silencePhrase = false
            // Under 0.3 s Whisper isn't asked, and nothing is typed.
            if levels.durationSec >= 0.3 {
                do {
                    let settings = job.settings.dictation
                    let samples = job.samples
                    let result = try transcriber.run { engine, tokens in
                        try DictationPipeline(engine: engine, settings: settings, options: TranscribeOptions(promptTokens: tokens(settings.vocabularyPrompt)))
                            .transcribe(samples, levels: levels)
                    }
                    let raw = result.rawTranscript ?? ""
                    let guarded = RepetitionLoopGuard.guardLoops(raw, durationSec: levels.durationSec)
                    if guarded != raw {
                        log(String(format: "Repetition loop %@: %d words from %.1fs → %@", guarded.isEmpty ? "dropped" : "collapsed",
                                   PythonText.split(raw).count, levels.durationSec, pythonRepr(guarded)))
                    }
                    text = result.text
                    update([
                        ("raw_transcript", .string(raw)),
                        ("decoded_text", .string(text)),
                        ("segments", .array((result.transcript?.segments ?? []).map(Self.segmentJSON))),
                    ])
                    if result.status == .skippedNearSilent {
                        // Recorded like Python's short-clip skip, with the reason alongside.
                        silencePhrase = true
                        update([("status", .string("skipped_low_level")), ("skip_reason", .string("long_near_silent"))])
                        pill.hide()
                        log(String(format: "Skipped near-silent clip: %.2fs rms=%.4f peak=%.4f, and Whisper only heard %@", levels.durationSec, levels.rms, levels.peak, pythonRepr(raw)))
                    } else {
                        log(String(format: "Transcribed %.1fs → %@", levels.durationSec, pythonRepr(text)))
                    }
                } catch {
                    log("Transcription error [\(Self.mode)]: \(error.localizedDescription)")
                    update([("status", .string("transcription_error")), ("error", .string(error.localizedDescription))])
                    text = ""
                }
            }
            let elapsed = now() - started
            timings.append(("transcribe_seconds", .double(elapsed)))
            if !text.isEmpty {
                // Saved before pasting, so the words survive whatever the paste does.
                update([("text", .string(text)), ("status", .string("completed"))])
                do { try history.append(text, mode: Self.mode) } catch {
                    log("Transcription history save failed: \(error.localizedDescription)")
                }
                log(String(format: "Done (%.2fs) [%@]: %@", elapsed, Self.mode, pythonRepr(text)))
                outcome.words = PythonText.split(text).count
                log("Injecting into \(pythonRepr(job.target?.name ?? "unknown")): \(pythonRepr(text))")
                let pasteStarted = now()
                let pasted: PasteOutcome
                do {
                    pasted = try paster.paste(text, into: job.target)
                } catch {
                    // Don't leave the processing pill up if the paste itself blew up.
                    pill.hide()
                    throw error
                }
                outcome.landed = pasted.landed
                timings.append(("paste_seconds", .double(now() - pasteStarted)))
                if let read = pasted.readLatency { timings.append(("paste_read_seconds", .double(read))) }
                timings.append(("key_up_to_paste_seconds", .double(now() - job.keyUpAt)))
                if pasted.landed && pasted.clipboard == .denied && !toldAboutClipboard {
                    // Once per run: the words landed, but the old clipboard is gone.
                    toldAboutClipboard = true
                    log("Clipboard access is denied for Voice Type Native, so the dictated text replaces whatever was on the clipboard. Allow it under System Settings > Privacy & Security > Paste from Other Apps (the Permissions window has a button).")
                    pill.showClipboardNotKept()
                } else if pasted.landed {
                    pill.showDone(words: outcome.words)
                } else {
                    // The text was left on the clipboard and Funk played.
                    pill.showPasteFailed()
                }
            } else if !silencePhrase {
                pill.hide()
                log(String(format: "Nothing to paste (%.2fs) [%@].", elapsed, Self.mode))
            }
            if outcome.status == "captured" { update([("status", .string("finished_without_text"))]) }
        } catch {
            update([("status", .string("finalization_error")), ("error", .string(error.localizedDescription))])
            log("Finalization failed: \(error.localizedDescription)")
        }
        update([("timings", .object(timings))])
        return outcome
    }

    static func segmentJSON(_ segment: TranscriptSegment) -> JSONValue {
        .object([
            ("text", .string(PythonText.strip(segment.text))),
            ("start", .double(segment.startSec)),
            ("end", .double(segment.endSec)),
            ("no_speech_prob", .double(segment.noSpeechProb)),
            ("token_p", .array(segment.tokenProbs.map { .double($0) })),
        ])
    }
}

/// Python's repr() of a string, so the log reads like voice-type.py's.
public func pythonRepr(_ s: String) -> String {
    let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
    var out = String(quote)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if Character(scalar) == quote { out += "\\\(quote)" } else if scalar.value < 0x20 || scalar.value == 0x7F {
                out += String(format: "\\x%02x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out.append(quote)
    return out
}
