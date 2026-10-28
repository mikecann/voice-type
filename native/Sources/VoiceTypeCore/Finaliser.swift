import Foundation

/// The speech engine as the controller and finaliser use it. InferenceWorker is the real one.
public protocol Transcribing: AnyObject, Sendable {
    var modelState: InferenceWorker.ModelState { get }
    func load(completion: @escaping (Result<Void, Error>) -> Void)
    func run<T>(_ body: @escaping (DictationEngine, (String?) -> [Int32]) throws -> T) throws -> T
    func preview(_ samples: [Float], prompt: String?, completion: @escaping (Transcript?) -> Void)
    func beginFinal()
    func endFinal()
    /// Screen marks: load the word timing engine ahead of key-up.
    func prepareWordTimings()
    /// Screen marks: starts a timing-only pass over `samples` on the timing engine's own
    /// thread. Its wait() is bounded by `timeout` and gives nil without a timing engine.
    func startWordTimings(_ samples: [Float], promptTokens: [Int32], timeout: Double) -> WordTimingPass
    /// After a wake: free the word timing engine, so the next mark makes a fresh one.
    func dropWordTimings(reason: String)
    /// Whether the word timing engine is loaded right now.
    var wordTimingsLoaded: Bool { get }
}

extension InferenceWorker: Transcribing {}

/// The pill as the controller drives it, from any thread. The app's version hops to the main
/// thread and calls PillController.
public protocol PillPresenting: AnyObject, Sendable {
    func showRecording(_ preview: String)
    /// The last seconds before the 120 s cap.
    func showSecondsLeft(_ seconds: Int)
    func showProcessing(_ preview: String)
    func showDone(words: Int)
    /// Words and screenshots pasted, for a dictation with screen marks.
    func showDone(words: Int, shots: Int)
    /// The paste didn't land. With `miss`, focus wasn't on a text box, and the pill says so.
    func showPasteFailed(_ miss: FocusMiss?)
    /// Marks were drawn but Screen Recording isn't allowed, so there are no screenshots.
    func showScreenRecordingHint()
    /// The paste landed, but the old clipboard couldn't be read, so it wasn't put back.
    func showClipboardNotKept()
    /// Dictations an earlier run left behind were transcribed and are in History.
    func showRecovered(count: Int, seconds: Double)
    func hide()
}

public protocol Pasting: AnyObject, Sendable {
    func paste(_ text: String, into target: TargetApp?) throws -> PasteOutcome
    func pasteSequence(text: String, images: [Data], into target: TargetApp?) throws -> Paster.SequenceOutcome
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
    /// What was drawn while the key was held, if anything. Without marks the dictation goes
    /// exactly as it always did.
    public var marks: DictationMarks?
    /// Deletes the copy of the audio written while the key was held, once the recording is
    /// saved properly.
    public var discardSpooled: (@Sendable () -> Void)?

    public init(samples: [Float], metadata: [(key: String, value: JSONValue)], preview: String, target: TargetApp?,
                settings: SettingsFile, keyUpAt: Double, stopAudioSeconds: Double, keyHoldSeconds: Double = 0, marks: DictationMarks? = nil) {
        self.samples = samples
        self.metadata = metadata
        self.preview = preview
        self.target = target
        self.settings = settings
        self.keyUpAt = keyUpAt
        self.stopAudioSeconds = stopAudioSeconds
        self.keyHoldSeconds = keyHoldSeconds
        self.marks = marks
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
    /// What a recording's "engine" field says.
    public static let engineName = "whisper.cpp b5454 ggml-large-v3-turbo-q8_0"

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
        // Saved, or the disk wouldn't take it: either way the partial copy is done with. Left
        // there, it would be transcribed again as a recovered dictation at the next launch.
        job.discardSpooled?()
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
                if job.marks != nil { log("Mark screenshots are kept on disk but not pasted.") }
                return outcome
            }
            if gated == .skippedLowLevel {
                update([("status", .string("skipped_low_level"))])
                pill.hide()
                log(String(format: "Skipped near-silent clip: %.2fs rms=%.4f peak=%.4f", levels.durationSec, levels.rms, levels.peak))
                if let marks = job.marks {
                    log("No words (near-silent clip); pasting \(marks.strokes.count) mark(s) on their own.")
                    let (paths, images) = loadScreenshots(marks)
                    update([("screenshots", .strings(paths))])
                    try pasteWithMarks("", images, marks, job: job, outcome: &outcome, timings: &timings)
                    update([("timings", .object(timings))])
                }
                return outcome
            }

            // The last preview stays up while the final pass runs.
            pill.showProcessing(job.preview)
            let started = now()
            log("Finalize mode: '\(Self.mode)'")
            var text = ""
            var transcript: Transcript?
            var promptTokens: [Int32] = []
            var silencePhrase = false
            // Under 0.3 s Whisper isn't asked, and nothing is typed.
            if levels.durationSec >= 0.3 {
                do {
                    let settings = job.settings.dictation
                    let samples = job.samples
                    // Word timings only for dictations with marks, to place their markers.
                    let wordTimings = job.marks != nil
                    let (result, tokensUsed) = try transcriber.run { engine, tokens in
                        let prompt = tokens(settings.vocabularyPrompt)
                        return (try DictationPipeline(engine: engine, settings: settings,
                                                      options: TranscribeOptions(promptTokens: prompt, wordTimings: wordTimings))
                            .transcribe(samples, levels: levels), prompt)
                    }
                    promptTokens = tokensUsed
                    transcript = result.transcript
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
                if let marks = job.marks {
                    // Bounded: the screenshots get 4 s plus 1 s a mark, the timing pass
                    // Deadlines.wordTiming, so the words below are always saved and pasted.
                    text = placeMarkers(text, marks, transcript: transcript, promptTokens: promptTokens, job: job, timings: &timings)
                }
                // Saved before pasting, so the words survive whatever the paste does.
                update([("text", .string(text)), ("status", .string("completed"))])
                do { try history.append(text, mode: Self.mode) } catch {
                    log("Transcription history save failed: \(error.localizedDescription)")
                }
                log(String(format: "Done (%.2fs) [%@]: %@", elapsed, Self.mode, pythonRepr(text)))
                outcome.words = PythonText.split(text).count
                if let marks = job.marks {
                    let (paths, images) = loadScreenshots(marks)
                    update([("screenshots", .strings(paths))])
                    try pasteWithMarks(text, images, marks, job: job, outcome: &outcome, timings: &timings)
                } else {
                    try pasteText(text, job: job, outcome: &outcome, timings: &timings)
                }
            } else if let marks = job.marks {
                log("No words (\(silencePhrase ? "near-silent clip" : String(format: "%.2fs [%@]", elapsed, Self.mode))); pasting \(marks.strokes.count) mark(s) on their own.")
                let (paths, images) = loadScreenshots(marks)
                update([("screenshots", .strings(paths))])
                try pasteWithMarks("", images, marks, job: job, outcome: &outcome, timings: &timings)
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

    private func pasteText(_ text: String, job: FinaliseJob, outcome: inout FinaliseOutcome, timings: inout [(key: String, value: JSONValue)]) throws {
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
            pill.showPasteFailed(pasted.focusMiss)
        }
    }

    // MARK: Screen marks

    /// Adds "[n]" for each captured mark where it was drawn in the speech, from Whisper's
    /// word timings, aligned to the corrected text. Waits for the screenshots first, since a
    /// mark whose capture failed gets no marker.
    ///
    /// The words' times come from a timing-only pass with whisper.cpp's DTW alignment, which
    /// put markers after the same word as Python's mlx-whisper timings 91% of the time on
    /// saved dictations (scripts/marker-check.py, which went with the Python version after
    /// commit 17e8220). Without it ("marker_timings": "rough",
    /// no timing engine, or a pass that ran out of time), the final pass's own token
    /// timestamps, which only managed 40%.
    ///
    /// The pass runs on its own thread, and starts before the wait for the screenshots, so
    /// the two overlap, when a screenshot is already in or the timing context is loaded
    /// already. Otherwise it waits for a screenshot to land, so the 1 GB context is never
    /// loaded for marks that can't be captured (the capture itself starts the load).
    private func placeMarkers(_ text: String, _ marks: DictationMarks, transcript: Transcript?, promptTokens: [Int32], job: FinaliseJob,
                              timings: inout [(key: String, value: JSONValue)]) -> String {
        let accurate = job.settings.markerTimings == .accurate
        let timeout = Deadlines.wordTiming(durationSec: Double(job.samples.count) / Double(sampleRate))
        var pass: WordTimingPass?
        var timingStarted = 0.0
        func startPass() {
            timingStarted = now()
            pass = transcriber.startWordTimings(job.samples, promptTokens: promptTokens, timeout: timeout)
        }
        if accurate && (marks.hasScreenshot || (marks.mayHaveScreenshots && transcriber.wordTimingsLoaded)) { startPass() }
        let waitStarted = now()
        let numbers = marks.numbers()
        timings.append(("screenshots_wait_seconds", .double(now() - waitStarted)))
        guard !numbers.isEmpty else {
            pass?.cancel()
            return text
        }
        if accurate && pass == nil { startPass() }
        var source = "token timestamp word"
        var words: [TimedText] = [], segments: [TimedText] = []
        if let pass {
            (words, segments) = MarkMarkers.timings(from: pass.wait())
            timings.append(("word_timing_seconds", .double(now() - timingStarted)))
            if pass.timedOut {
                log(String(format: "The word timing pass took over %.1fs; placing markers with the final pass's token timestamps instead.", timeout))
            }
            if !words.isEmpty { source = "DTW word" }
        }
        if words.isEmpty { (words, segments) = MarkMarkers.timings(from: transcript) }
        let spoken = (words.isEmpty ? segments : words).map(\.text).joined(separator: " ")
        let counts = MarkMarkers.spokenWordCounts(marks.audioTimes(numbers), words: words, segments: segments)
        let placed = MarkMarkers.insertMarkers(text, spoken: spoken, wordCounts: counts, numbers: numbers)
        log("Placed \(numbers.count) mark marker(s) using \(!words.isEmpty ? source : !segments.isEmpty ? "segment" : "no") timings.")
        return placed
    }

    /// The screenshots to paste, one per window, in order of each one's lowest mark, and
    /// their bytes. Waits for the capture worker if it's still going.
    private func loadScreenshots(_ marks: DictationMarks) -> (paths: [String], images: [Data]) {
        let paths = marks.imagePaths()
        var images: [Data] = []
        for path in paths {
            do { images.append(try Data(contentsOf: URL(fileURLWithPath: path))) } catch {
                log("Could not read mark screenshot \(path): \(error.localizedDescription)")
            }
        }
        return (paths, images)
    }

    /// Pastes the text (if any) and then the marks' screenshots, and shows how it went. Marks
    /// on the same window share one screenshot. A mark whose capture failed (or every mark,
    /// without Screen Recording) just isn't pasted; the words still are.
    private func pasteWithMarks(_ text: String, _ images: [Data], _ marks: DictationMarks, job: FinaliseJob, outcome: inout FinaliseOutcome,
                                timings: inout [(key: String, value: JSONValue)]) throws {
        guard !images.isEmpty else {
            if !PythonText.strip(text).isEmpty { try pasteText(text, job: job, outcome: &outcome, timings: &timings) } else { pill.hide() }
            if marks.permissionMissing { pill.showScreenRecordingHint() }
            return
        }
        log("Injecting into \(pythonRepr(job.target?.name ?? "unknown")): \(pythonRepr(text)) + \(images.count) screenshot(s)")
        let pasteStarted = now()
        let pasted: Paster.SequenceOutcome
        do {
            pasted = try paster.pasteSequence(text: text, images: images, into: job.target)
        } catch {
            pill.hide()
            throw error
        }
        outcome.landed = pasted.landed
        timings.append(("paste_seconds", .double(now() - pasteStarted)))
        timings.append(("key_up_to_paste_seconds", .double(now() - job.keyUpAt)))
        if pasted.landed && pasted.clipboard == .denied && !toldAboutClipboard {
            toldAboutClipboard = true
            log("Clipboard access is denied for Voice Type Native, so the dictated text and screenshots replace whatever was on the clipboard. Allow it under System Settings > Privacy & Security > Paste from Other Apps (the Permissions window has a button).")
            pill.showClipboardNotKept()
        } else if pasted.landed {
            pill.showDone(words: PythonText.split(text).count, shots: images.count)
        } else {
            pill.showPasteFailed(pasted.focusMiss)
        }
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
