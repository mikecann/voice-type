import Foundation
import VoiceTypeCore
import VoiceTypeWhisper

/// Times each call to the engine, so serve can report Whisper's time on its own, as
/// whispercpp-bench's "ms" does, apart from reading files and the gates.
final class TimedEngine: SpeechEngine {
    let inner: SpeechEngine
    private(set) var lastMilliseconds: Double = 0

    init(_ inner: SpeechEngine) { self.inner = inner }

    func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { lastMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
        return try inner.transcribe(samples, options: options)
    }
}

struct CLI {
    let options: Options

    func loadEngine() -> WhisperEngine {
        do {
            return try WhisperEngine(modelPath: options.model, useGPU: options.useGPU, threads: options.threads, dtw: options.dtw)
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    /// The pipeline with the word list and corrections from settings.json.
    func makePipeline(_ engine: WhisperEngine, timed: TimedEngine? = nil) -> DictationPipeline {
        let settings = VoiceTypeSettings.load(from: options.settings)
        let tokens = engine.promptTokens(for: settings.vocabularyPrompt)
        return DictationPipeline(engine: timed ?? engine, settings: settings,
                                 options: TranscribeOptions(promptTokens: tokens, wordTimings: options.wordTimings))
    }

    /// The full pipeline, or with --raw only Whisper.
    func process(_ samples: [Float], with pipeline: DictationPipeline) throws -> DictationResult {
        options.raw ? try pipeline.runEngineOnly(samples) : try pipeline.run(samples)
    }

    // MARK: history

    /// The History window's list, newest first, for checking it against the files.
    func history() {
        let limit = options.positional.first.flatMap(Int.init) ?? 20
        let started = Date()
        let items = DictationHistory.load(recordings: options.recordings, historyFile: VoiceTypePaths.historyFile)
        let took = Date().timeIntervalSince(started)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for item in items.prefix(limit) {
            var notes: [String] = []
            if let seconds = item.durationSec { notes.append(String(format: "%.1fs", seconds)) }
            if item.audioURL == nil { notes.append("no audio") }
            if !item.screenshots.isEmpty { notes.append("\(item.screenshots.count) shot(s)") }
            if item.recovered { notes.append("recovered") }
            if item.correctedText != nil { notes.append("fixed") }
            let text = item.bestText.isEmpty ? "(\(item.outcome))" : item.bestText
            print("\(formatter.string(from: item.date))  [\(notes.joined(separator: ", "))]  \(text)")
        }
        FileHandle.standardError.write(Data(String(format: "%d dictations, read in %.0f ms\n", items.count, took * 1000).utf8))
    }

    // MARK: transcribe

    func transcribe() {
        guard let path = options.positional.first else { fail("transcribe needs a WAV file\n\n\(usage)") }
        let samples: [Float]
        do { samples = try WAVReader.read(URL(fileURLWithPath: path)) } catch { fail("\(path): \(error.localizedDescription)", code: 1) }
        let pipeline = makePipeline(loadEngine())
        do {
            let result = try process(samples, with: pipeline)
            if result.text.isEmpty {
                FileHandle.standardError.write(Data("(\(result.status.rawValue): nothing to type)\n".utf8))
            }
            print(result.text)
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    // MARK: serve

    /// whispercpp-bench's protocol, so the benchmark can point a key at this: one JSON
    /// request per stdin line, {"id": ..., "path": FILE, "prompt_tokens": [...], "beam": N},
    /// one JSON reply per stdout line, after a {"ready": true, ...} line once the model loads.
    ///
    /// FILE is raw float32 at 16 kHz, as the benchmark writes it, or a WAV. Without
    /// prompt_tokens the word list comes from settings.json and is tokenized here, which is
    /// what a native benchmark key should test; with them, they're used as given.
    func serve() {
        let engine = loadEngine()
        let timed = TimedEngine(engine)
        var pipeline = makePipeline(engine, timed: timed)
        let defaultTokens = pipeline.options.promptTokens
        emit(["ready": true, "load_ms": engine.loadMilliseconds, "pid": Int(getpid()), "raw": options.raw, "word_timings": options.wordTimings])

        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let id = request["id"] ?? ""
            guard let path = request["path"] as? String else {
                emit(["id": id, "error": "request has no path", "text": "", "ms": 0])
                continue
            }
            pipeline.options.promptTokens = (request["prompt_tokens"] as? [Int])?.compactMap(Int32.init(exactly:)) ?? defaultTokens
            pipeline.options.beamSize = request["beam"] as? Int ?? 0
            do {
                let samples = try WAVReader.readAudioFile(URL(fileURLWithPath: path))
                let result = try process(samples, with: pipeline)
                let ran = result.transcript != nil
                var reply: [String: Any] = [
                    "id": id,
                    "text": result.text,
                    "ms": ran ? timed.lastMilliseconds : 0,
                    "status": result.status.rawValue,
                    "seconds": result.levels.durationSec,
                    "rms": result.levels.rms,
                    "peak": result.levels.peak,
                    "segments": (result.transcript?.segments ?? []).map { segment -> [String: Any] in
                        var fields: [String: Any] = [
                            "text": PythonText.strip(segment.text),
                            "no_speech_prob": segment.noSpeechProb,
                            "token_p": segment.tokenProbs,
                        ]
                        if options.wordTimings {
                            fields["start"] = segment.startSec
                            fields["end"] = segment.endSec
                            fields["words"] = segment.words.map { [$0.start, $0.end, $0.text] as [Any] }
                        }
                        return fields
                    },
                ]
                if let raw = result.rawTranscript { reply["raw_text"] = raw }
                emit(reply)
            } catch {
                emit(["id": id, "error": error.localizedDescription, "text": "", "ms": 0])
            }
        }
    }

    private func emit(_ object: [String: Any]) {
        // Written straight to the file handle rather than print(), so each reply goes out
        // as soon as it's ready even though stdout is a pipe.
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }

    // MARK: replay

    /// Reruns saved recordings and prints each one whose text differs from what was typed
    /// when it was recorded. Older recordings are the Python version's, which ran
    /// mlx-whisper, so differences are expected; this is for finding them, not a pass or fail.
    func replay() {
        guard let since = options.since else { fail("replay needs --since DATE\n\n\(usage)") }
        let recordings: [SavedRecording]
        do {
            recordings = try RecordingArchiveReader.list(in: options.recordings, since: since)
        } catch {
            fail("can't read \(options.recordings.path): \(error.localizedDescription)", code: 1)
        }
        let pipeline = makePipeline(loadEngine())
        var same = 0, different = 0, skipped = 0
        var results: [String: Any] = [:]
        for recording in recordings {
            // "captured" means the app was still finishing it, or crashed before it did.
            guard recording.status != "captured" else { skipped += 1; continue }
            let samples: [Float]
            do { samples = try WAVReader.read(recording.audioURL) } catch {
                print("\(recording.id): can't read audio: \(error.localizedDescription)")
                skipped += 1
                continue
            }
            let saved = recording.comparableText
            let result: DictationResult
            do { result = try process(samples, with: pipeline) } catch {
                print("\(recording.id): \(error.localizedDescription)")
                skipped += 1
                continue
            }
            results[recording.id] = [
                "saved": saved,
                "native": result.text,
                "saved_status": recording.status,
                "native_status": result.status.pythonStatus,
                "seconds": result.levels.durationSec,
            ]
            if saved == result.text {
                same += 1
                continue
            }
            different += 1
            let marks = recording.markCount > 0 ? ", marks left out" : ""
            print(String(format: "%@  %.1f s%@", recording.id, result.levels.durationSec, marks))
            print("  saved  (\(recording.status)): \(saved)")
            print("  native (\(result.status.pythonStatus)): \(result.text)")
            // stdout is block-buffered when it goes to a file, and a long replay should
            // show its progress as it goes.
            fflush(nil)
        }
        print("\(recordings.count) recordings since \(since): \(same) same, \(different) different, \(skipped) skipped")
        if let json = options.json {
            do {
                let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: json))
            } catch {
                fail("can't write \(json): \(error.localizedDescription)", code: 1)
            }
        }
    }

    // MARK: composite

    /// Draws marks onto a PNG and shrinks, quantizes and saves it exactly as the app does
    /// with a capture, so the compositor can be checked without holding the key.
    func composite() {
        guard options.positional.count == 2, let rectText = options.rect else { fail("composite needs IN.png OUT.png --rect X,Y,W,H\n\n\(usage)") }
        let numbers = rectText.split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { fail("--rect needs four numbers: X,Y,W,H") }
        var strokes: [Stroke] = []
        if let marks = options.marks {
            guard let data = FileManager.default.contents(atPath: marks),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { fail("can't read \(marks)") }
            strokes = list.enumerated().map { i, mark in
                let points = (mark["points"] as? [[Double]] ?? []).map { MarkPoint($0[0], $0[1]) }
                return Stroke(points: points, startedAt: 0, endedAt: 1, number: mark["number"] as? Int ?? i + 1)
            }
        }
        do {
            let input = try Data(contentsOf: URL(fileURLWithPath: options.positional[0]))
            let started = DispatchTime.now().uptimeNanoseconds
            let png = try MarkCompositor.compositePNG(input, captureRect: MarkRect(numbers[0], numbers[1], numbers[2], numbers[3]), strokes: strokes)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            try png.write(to: URL(fileURLWithPath: options.positional[1]))
            print(String(format: "%@: %d KB -> %d KB in %.0f ms (%@)", options.positional[1], input.count / 1024, png.count / 1024, ms,
                         strokes.map(\.kind.rawValue).joined(separator: ", ")))
        } catch {
            fail(error.localizedDescription, code: 1)
        }
    }

    // MARK: tokens

    /// Prints the word list prompt's tokens from our tiktoken-style tokenizer and from
    /// whisper.cpp's whisper_tokenize, to show whether they agree.
    func tokens() {
        let settings = VoiceTypeSettings.load(from: options.settings)
        guard let prompt = settings.vocabularyPrompt else {
            print("no word list, so no prompt")
            return
        }
        let engine = loadEngine()
        let input = VocabularyPrompt.tokenizerInput(for: prompt)
        let ours = engine.tokenizer.encode(input)
        let theirs = engine.whisperCppTokenize(input)
        print("prompt: \(input.debugDescription)")
        print("tiktoken BPE (\(ours.count)): \(ours)")
        print("whisper_tokenize (\(theirs.count)): \(theirs)")
        print(ours == theirs ? "same" : "different")
    }
}
