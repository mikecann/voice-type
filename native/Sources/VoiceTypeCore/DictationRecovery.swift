import Foundation

/// A dictation found after a crash and transcribed, for the pill and the menu.
public struct RecoveredDictation: Equatable, Sendable {
    public var id: String
    public var durationSec: Double
    /// What it said, or "" if there was nothing to type.
    public var text: String
}

/// Finishes dictations an earlier run of the app didn't (the rest of issue #7).
///
/// Two ways one gets left behind: the app went down while the key was held, leaving the
/// audio written so far in a `.wav.partial` file (RecordingSpool), or it went down after
/// key-up, between saving the recording and transcribing it, leaving a recording whose status
/// is still "captured". Either way it's transcribed now with the same word list, gates, loop
/// guard and corrections, and goes into the recording and the history, marked recovered. It's
/// never pasted: by now whatever it was for has moved on.
///
/// Each attempt is counted in the recording before Whisper sees it, and a recording gets two,
/// so one that crashes the app (or hangs, and a watchdog restarts it) isn't tried at every
/// launch, while one cut off by an unrelated restart still gets another go. Only the last two
/// days are looked at, so a stray old recording doesn't pop up out of nowhere.
///
/// Runs on the finalise lane, so it never overlaps a dictation's own finalisation.
public final class DictationRecovery: @unchecked Sendable {
    public static let lookBackSeconds = 48.0 * 3600
    public static let maxAttempts = 2

    /// One recording waiting to be transcribed.
    public struct Pending: Equatable, Sendable {
        public var id: String
        public var durationSec: Double
    }

    private let archive: RecordingArchive
    private let history: TranscriptionHistory
    private let transcriber: Transcribing
    private let log: (String) -> Void
    private let clock: () -> Date
    private let timeZone: TimeZone

    public init(archive: RecordingArchive, history: TranscriptionHistory, transcriber: Transcribing,
                log: @escaping (String) -> Void, clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.archive = archive
        self.history = history
        self.transcriber = transcriber
        self.log = log
        self.clock = clock
        self.timeZone = timeZone
    }

    /// Turns partial files into recordings, then lists every recording waiting to be
    /// transcribed. Doesn't need the model.
    public func prepare(settings: SettingsFile) -> [Pending] {
        adoptPartialFiles(settings: settings)
        return pending()
    }

    func adoptPartialFiles(settings: SettingsFile) {
        let cutoff = clock().addingTimeInterval(-Self.lookBackSeconds)
        for url in RecordingSpool.leftovers(in: archive.directory) {
            func delete() { try? FileManager.default.removeItem(at: url) }
            guard let capturedAt = RecordingSpool.capturedAt(url), capturedAt >= cutoff else {
                delete()
                continue
            }
            do {
                let samples = try RecordingSpool.samples(in: url)
                // Under 0.3 s nothing would be typed anyway.
                guard Double(samples.count) >= 0.3 * Double(sampleRate) else {
                    delete()
                    continue
                }
                let metadata: [(key: String, value: JSONValue)] = [
                    ("mode", .string(Finaliser.mode)),
                    ("vocabulary", settings.vocabularyForRecording),
                    ("app", .string("native")),
                    ("engine", .string(Finaliser.engineName)),
                    ("recovered_from", .string("partial")),
                ]
                let id = try archive.save(samples, sampleRate: sampleRate, metadata: metadata, capturedAt: capturedAt)
                // Only now: until it's a recording, the partial file is the only copy.
                delete()
                log(String(format: "Found %.1fs of audio from a dictation that was cut off; saved it as %@.", Double(samples.count) / Double(sampleRate), id))
            } catch {
                log("Couldn't recover \(url.lastPathComponent) (kept for next time): \(error.localizedDescription)")
            }
        }
    }

    /// Recordings from the last two days still "captured" with attempts left, oldest first.
    func pending() -> [Pending] {
        let cutoff = Timestamp(clock().addingTimeInterval(-Self.lookBackSeconds))
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: archive.directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()
        return names.compactMap { name -> Pending? in
            // The name says when it was captured, so only the last two days get parsed.
            guard let created = RecordingArchive.captureTime(ofFileNamed: name), created >= cutoff else { return nil }
            let id = String(name.dropLast(5))
            guard let entry = archive.entry(id), entry["status"]?.stringValue == "captured",
                  Self.attempts(entry) < Self.maxAttempts else { return nil }
            let seconds = entry["duration_seconds"].flatMap { Double($0.numberLiteral ?? "") } ?? 0
            return Pending(id: id, durationSec: seconds)
        }
    }

    /// Transcribes one pending recording and saves the result. Nil if its audio is gone.
    public func recover(_ item: Pending, settings: SettingsFile) -> RecoveredDictation? {
        guard let entry = archive.entry(item.id), let audioFile = entry["audio_file"]?.stringValue else { return nil }
        let samples: [Float]
        do {
            samples = try WAVReader.read(archive.directory.appendingPathComponent(audioFile))
        } catch {
            log("Couldn't read the audio of \(item.id) to recover it: \(error.localizedDescription)")
            try? archive.update(item.id, [("recovery_attempts", .int(Self.maxAttempts))])
            return nil
        }
        // Before Whisper runs, so a recording that brings the app down isn't tried forever.
        do { try archive.update(item.id, [("recovery_attempts", .int(Self.attempts(entry) + 1))]) } catch {
            log("Couldn't mark \(item.id) as being recovered (\(error.localizedDescription)); leaving it.")
            return nil
        }
        let levels = AudioLevels(samples: samples)
        var fields: [(key: String, value: JSONValue)] = [("recovered", .bool(true))]
        var text = ""
        if let gated = DictationPipeline.gate(levels) {
            fields.append(("status", .string(gated.status.pythonStatus)))
        } else {
            do {
                let result = try transcribe(samples, levels: levels, settings: settings)
                text = result.status == .skippedNearSilent ? "" : result.text
                fields.append(contentsOf: [
                    ("raw_transcript", .string(result.rawTranscript ?? "")),
                    ("decoded_text", .string(result.text)),
                    ("segments", .array((result.transcript?.segments ?? []).map(Finaliser.segmentJSON))),
                ])
                if result.status == .skippedNearSilent {
                    fields.append(contentsOf: [("status", .string("skipped_low_level")), ("skip_reason", .string("long_near_silent"))])
                } else if text.isEmpty {
                    fields.append(("status", .string("finished_without_text")))
                } else {
                    fields.append(contentsOf: [("text", .string(text)), ("status", .string("completed"))])
                }
            } catch {
                log("Transcription error while recovering \(item.id): \(error.localizedDescription)")
                fields.append(contentsOf: [("status", .string("transcription_error")), ("error", .string(error.localizedDescription))])
            }
        }
        do { try archive.update(item.id, fields) } catch { log("Recording metadata update failed: \(error.localizedDescription)") }
        if !text.isEmpty {
            // Filed under when it was said, not now.
            let said = entry["created_at"]?.stringValue.flatMap { Timestamp.parseISO($0)?.timestamp(assumingOffset: 0) } ?? Timestamp(clock())
            do { try history.append(text, mode: Finaliser.mode, createdAt: said.localISOFormatSeconds(timeZone: timeZone)) } catch {
                log("Transcription history save failed: \(error.localizedDescription)")
            }
            log(String(format: "Recovered a %.1fs dictation: %@", levels.durationSec, pythonRepr(text)))
        } else {
            log(String(format: "Recovered a %.1fs dictation, but there was nothing to type.", levels.durationSec))
        }
        return RecoveredDictation(id: item.id, durationSec: levels.durationSec, text: text)
    }

    static func attempts(_ entry: JSONValue) -> Int {
        entry["recovery_attempts"].flatMap { Int($0.numberLiteral ?? "") } ?? 0
    }

    /// History's "Transcribe again": Whisper, the loop guard and corrections on a saved
    /// recording, without the gates (they're usually why it has no text). The result goes in
    /// the recording as `retranscribed_text`, apart from what was typed. Nil if the audio is
    /// gone or too short to transcribe.
    public func retranscribe(_ id: String, settings: SettingsFile) throws -> String? {
        guard let entry = archive.entry(id), let audioFile = entry["audio_file"]?.stringValue else { return nil }
        let samples = try WAVReader.read(archive.directory.appendingPathComponent(audioFile))
        let levels = AudioLevels(samples: samples)
        guard levels.durationSec >= 0.3 else { return nil }
        let result = try transcribe(samples, levels: levels, settings: settings)
        // A near-silent clip's "Thank you." is still what Whisper heard, which is the point here.
        let text = result.text.isEmpty ? settings.dictation.corrections.apply(result.rawTranscript ?? "") : result.text
        try archive.update(id, [("retranscribed_text", .string(text))])
        log(String(format: "Transcribed %@ again: %@", id, pythonRepr(text)))
        return text
    }

    private func transcribe(_ samples: [Float], levels: AudioLevels, settings: SettingsFile) throws -> DictationResult {
        let dictation = settings.dictation
        return try transcriber.run { engine, tokens in
            try DictationPipeline(engine: engine, settings: dictation,
                                  options: TranscribeOptions(promptTokens: tokens(dictation.vocabularyPrompt)))
                .transcribe(samples, levels: levels)
        }
    }
}
