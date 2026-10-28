import Foundation
import Testing
@testable import VoiceTypeCore

// Phase 3: audio written while the key is held, recovering dictations a crash cut off, the
// History window's list, "Fix it", and the settings window's edits.

private func partialFiles(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".wav.partial") }.sorted()
}

private func speech(_ seconds: Double) -> [Float] { ControllerHarness.speech(seconds: seconds) }

struct RecordingSpoolTests {
    @Test func writesTheHeaderAndEveryBlockAndReadsThemBack() throws {
        let dir = try temporaryDirectory("spool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let at = Date(timeIntervalSince1970: 1_792_548_000.25)
        let spool = RecordingSpool(directory: dir, clock: { at }, makeHexID: { String(repeating: "a", count: 32) }, log: { _ in })
        spool.append([9, 9])  // nothing's being recorded yet
        let session = spool.begin()
        spool.append([0.1, -0.2])
        spool.append([0.3])
        spool.end(session)
        spool.append([7])  // after the key went up
        spool.flush()
        #expect(session.url.lastPathComponent == "\(Timestamp(at).recordingIDPrefix)_\(String(repeating: "a", count: 32)).wav.partial")
        #expect(RecordingSpool.leftovers(in: dir) == [session.url])
        #expect(try RecordingSpool.samples(in: session.url) == [0.1, -0.2, 0.3])
        #expect(RecordingSpool.capturedAt(session.url) == Timestamp(at).date)
        // Owner-only, like the recordings.
        let mode = try FileManager.default.attributesOfItem(atPath: session.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // The header is a recording's, with no samples counted yet.
        let data = try Data(contentsOf: session.url)
        #expect(data.prefix(RecordingSpool.headerBytes) == RecordingArchive.wavData([], sampleRate: sampleRate))
    }

    @Test func discardNowHasDeletedTheFileWhenItReturns() throws {
        let dir = try temporaryDirectory("spool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = RecordingSpool(directory: dir, log: { _ in })
        let session = spool.begin()
        spool.append([0.5])
        spool.end(session)
        spool.discardNow(session)
        #expect(partialFiles(dir).isEmpty)
    }

    @Test func discardDeletesTheFile() throws {
        let dir = try temporaryDirectory("spool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let spool = RecordingSpool(directory: dir, log: { _ in })
        let session = spool.begin()
        spool.append([0.5])
        spool.end(session)
        spool.discard(session)
        spool.flush()
        #expect(partialFiles(dir).isEmpty)
    }

    @Test func oldPartialFilesAreCleanedUpWithTheRecordings() throws {
        let dir = try temporaryDirectory("spool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Date().addingTimeInterval(-31 * 86_400)
        let spool = RecordingSpool(directory: dir, clock: { old }, log: { _ in })
        spool.end(spool.begin())
        spool.flush()
        #expect(partialFiles(dir).count == 1)
        #expect(RecordingArchive(directory: dir).cleanup() == 1)
        #expect(partialFiles(dir).isEmpty)
    }
}

struct SpoolingDictationTests {
    @Test func theAudioIsOnDiskWhileTheKeyIsHeldAndGoesOnceSaved() throws {
        let h = try ControllerHarness(spool: true)
        h.startAndBecomeReady()
        h.press()
        let said = speech(1.5)
        h.factory.deliver(said)
        h.executor.drain()
        h.spool!.flush()
        let recordings = h.directory.appendingPathComponent("recordings")
        let partial = partialFiles(recordings)
        #expect(partial.count == 1)
        #expect(try RecordingSpool.samples(in: recordings.appendingPathComponent(partial[0])) == said)
        h.release()
        h.spool!.flush()
        // Saved as a recording now, so the partial copy is gone.
        #expect(partialFiles(recordings).isEmpty)
        #expect(h.recordingEntries().count == 1)
        #expect(h.paster.pasted.map(\.text) == ["Port it to CUDA."])
    }

    @Test func nothingIsSpooledWhenRecordingsAreOff() throws {
        let h = try ControllerHarness(settings: .object([("audio_recording_enabled", .bool(false))]), spool: true)
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(speech(1))
        h.executor.drain()
        h.spool!.flush()
        #expect(partialFiles(h.directory.appendingPathComponent("recordings")).isEmpty)
        h.release()
        #expect(h.paster.pasted.map(\.text) == ["Port it to CUDA."])
    }

    @Test func aFailedStartLeavesNoPartialFile() throws {
        let h = try ControllerHarness(spool: true)
        h.startAndBecomeReady()
        h.factory.failOpen = true
        h.recorder.invalidate()
        h.press()
        h.release()
        h.spool!.flush()
        #expect(partialFiles(h.directory.appendingPathComponent("recordings")).isEmpty)
    }
}

struct RecoveryTests {
    /// A partial file like the one a crash mid-dictation leaves, from a minute ago.
    static func leavePartial(_ samples: [Float], in data: URL, ago: Double = 60) {
        let spool = RecordingSpool(directory: data.appendingPathComponent("recordings"), clock: { Date().addingTimeInterval(-ago) }, log: { _ in })
        let session = spool.begin()
        spool.append(samples)
        spool.end(session)
        spool.flush()
    }

    @Test func aDictationCutOffMidwayIsTranscribedIntoTheHistoryButNotPasted() throws {
        let h = try ControllerHarness(spool: true, recovery: true, beforeStart: { RecoveryTests.leavePartial(speech(2), in: $0) })
        h.startAndBecomeReady()
        let entries = h.recordingEntries()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry["status"]?.stringValue == "completed")
        #expect(entry["text"]?.stringValue == "Port it to CUDA.")
        #expect(entry["recovered"] == .bool(true))
        #expect(entry["recovered_from"]?.stringValue == "partial")
        #expect(entry["recovery_attempts"] == .int(1))
        #expect(entry["duration_seconds"] == .double(2))
        #expect(partialFiles(h.directory.appendingPathComponent("recordings")).isEmpty)
        #expect(try h.history.load().map(\.text) == ["Port it to CUDA."])
        #expect(h.paster.pasted.isEmpty)
        #expect(h.recovered.map(\.text) == ["Port it to CUDA."])
        #expect(h.pill.last == "recovered:1")
        #expect(h.watchdogs.map(\.name).contains("recovery"))
    }

    @Test func aRecordingSavedButNeverTranscribedIsRecovered() throws {
        let h = try ControllerHarness(recovery: true, beforeStart: { data in
            try RecordingArchive(directory: data.appendingPathComponent("recordings"))
                .save(speech(1), sampleRate: sampleRate, metadata: [("mode", .string("final_only"))])
        })
        // The recording is marked before Whisper sees it, so one that brings the app down
        // isn't tried at every launch.
        var markedFirst = false
        h.engine.duringTranscribe = { markedFirst = h.recordingEntries().first?["recovery_attempts"] == .int(1) }
        h.startAndBecomeReady()
        #expect(markedFirst)
        #expect(h.recordingEntries().first?["status"]?.stringValue == "completed")
        #expect(h.recovered.count == 1)
        // And never again.
        #expect(h.recovery!.prepare(settings: SettingsFile(url: h.directory, json: .object([]))).isEmpty)
    }

    @Test func oneThatWasAlreadyTriedOrIsOldIsLeftAlone() throws {
        let h = try ControllerHarness(recovery: true, beforeStart: { data in
            let recordings = data.appendingPathComponent("recordings")
            let tried = try RecordingArchive(directory: recordings).save(speech(1), sampleRate: sampleRate, metadata: [])
            try RecordingArchive(directory: recordings).update(tried, [("recovery_attempts", .int(2))])
            let threeDaysAgo = Date().addingTimeInterval(-3 * 86_400)
            try RecordingArchive(directory: recordings, clock: { threeDaysAgo }).save(speech(1), sampleRate: sampleRate, metadata: [])
            RecoveryTests.leavePartial(speech(1), in: data, ago: 3 * 86_400)
        })
        h.startAndBecomeReady()
        #expect(h.recovered.isEmpty)
        #expect(h.engine.finals.isEmpty)
        #expect(h.recordingEntries().allSatisfy { $0["status"]?.stringValue == "captured" })
        // The old partial file is deleted rather than recovered.
        #expect(partialFiles(h.directory.appendingPathComponent("recordings")).isEmpty)
        #expect(h.pill.calls.isEmpty)
    }

    @Test func oneCutOffMidRecoveryGetsASecondGo() throws {
        let h = try ControllerHarness(recovery: true, beforeStart: { data in
            let recordings = data.appendingPathComponent("recordings")
            let once = try RecordingArchive(directory: recordings).save(speech(1), sampleRate: sampleRate, metadata: [])
            try RecordingArchive(directory: recordings).update(once, [("recovery_attempts", .int(1))])
        })
        h.startAndBecomeReady()
        #expect(h.recovered.map(\.text) == ["Port it to CUDA."])
        #expect(h.recordingEntries().first?["recovery_attempts"] == .int(2))
    }

    @Test func aRestartWaitsForRecoveryToFinish() throws {
        let lane = ManualExecutor()
        let h = try ControllerHarness(finaliseLane: lane, recovery: true, beforeStart: { RecoveryTests.leavePartial(speech(2), in: $0) })
        h.startAndBecomeReady()
        var restarted = false
        h.controller.whenIdle("Restarting") { restarted = true }
        #expect(!restarted)
        #expect(h.logs.contains("Restarting once the dictation being recovered is done."))
        lane.drain()
        h.executor.drain()
        #expect(restarted)
        #expect(h.phase == .stopping)
        #expect(h.recordingEntries().first?["status"]?.stringValue == "completed")
    }

    @Test func aPartialFileIsKeptWhenItCantBeSaved() throws {
        let dir = try temporaryDirectory("recovery")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        RecoveryTests.leavePartial(speech(1), in: dir)
        let partial = try #require(RecordingSpool.leftovers(in: recordings).first)
        let at = try #require(RecordingSpool.capturedAt(partial))
        let hex = String(repeating: "b", count: 32)
        // Something in the way of the recording's file, like a full disk would be.
        try FileManager.default.createDirectory(at: recordings.appendingPathComponent("\(Timestamp(at).recordingIDPrefix)_\(hex).wav"), withIntermediateDirectories: true)
        let archive = RecordingArchive(directory: recordings, makeHexID: { hex })
        let engine = ScriptedEngine(["Hello."])
        var logs: [String] = []
        let recovery = DictationRecovery(archive: archive, history: TranscriptionHistory(url: dir.appendingPathComponent("h.jsonl")),
                                         transcriber: FakeTranscriber(engine), log: { logs.append($0) })
        #expect(recovery.prepare(settings: SettingsFile(url: dir, json: .object([]))).isEmpty)
        #expect(RecordingSpool.leftovers(in: recordings) == [partial])
        #expect(logs.contains { $0.contains("kept for next time") })
    }

    @Test func silenceIsRecordedAsSuchAndNotAnnounced() throws {
        let h = try ControllerHarness(recovery: true, beforeStart: { RecoveryTests.leavePartial([Float](repeating: 0, count: sampleRate * 2), in: $0) })
        h.startAndBecomeReady()
        #expect(h.recordingEntries().first?["status"]?.stringValue == "flatline_capture")
        #expect(h.recovered.map(\.text) == [""])
        #expect(try h.history.load().isEmpty)
        #expect(!h.pill.calls.contains { $0.hasPrefix("recovered") })
    }

    @Test func aTinyPartialFileIsJustDeleted() throws {
        let h = try ControllerHarness(recovery: true, beforeStart: { RecoveryTests.leavePartial(speech(0.1), in: $0) })
        h.startAndBecomeReady()
        #expect(h.recordingEntries().isEmpty)
        #expect(partialFiles(h.directory.appendingPathComponent("recordings")).isEmpty)
    }

    @Test func transcribeAgainSkipsTheGatesAndKeepsTheTypedTextAlone() throws {
        let h = try ControllerHarness(recovery: true)
        h.startAndBecomeReady()
        let quiet = [Float]((0..<(sampleRate / 2)).map { $0 % 2 == 0 ? 0.002 : -0.002 })
        h.dictate(quiet)
        let id = try #require(h.recordingEntries().first?["id"]?.stringValue)
        #expect(h.recordingEntries().first?["status"]?.stringValue == "skipped_low_level")
        let text = try h.recovery!.retranscribe(id, settings: SettingsFile(url: h.directory, json: .object([])))
        #expect(text == "Port it to CUDA.")
        let entry = try #require(h.recordingEntries().first)
        #expect(entry["retranscribed_text"]?.stringValue == "Port it to CUDA.")
        #expect(entry["status"]?.stringValue == "skipped_low_level")
        #expect(entry["text"] == nil)
    }
}

struct DictationHistoryTests {
    @Test func mergesTheRecordingsWithLinesThatHaveNoRecording() throws {
        let dir = try temporaryDirectory("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        let base = Date(timeIntervalSince1970: 1_792_548_000)
        let typed = try RecordingArchive(directory: recordings, clock: { base }).save(speech(1), sampleRate: sampleRate, metadata: [])
        try RecordingArchive(directory: recordings).update(typed, [("status", .string("completed")), ("text", .string("Hello there.")),
                                                                    ("screenshots", .strings(["/nowhere/gone.png"]))])
        let skipped = try RecordingArchive(directory: recordings, clock: { base.addingTimeInterval(60) })
            .save(speech(0.5), sampleRate: sampleRate, metadata: [])
        try RecordingArchive(directory: recordings).update(skipped, [("status", .string("skipped_low_level"))])
        let historyFile = dir.appendingPathComponent("transcription-history.jsonl")
        let utc = TimeZone(secondsFromGMT: 0)!
        // Written a second after its recording, as the finaliser does.
        let lines = [
            (Timestamp(base.addingTimeInterval(1)).localISOFormatSeconds(timeZone: utc), "Hello there."),
            (Timestamp(base.addingTimeInterval(-600)).localISOFormatSeconds(timeZone: utc), "Only in the history."),
        ].map { #"{"created_at": "\#($0.0)", "mode": "final_only", "text": "\#($0.1)"}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: historyFile, atomically: true, encoding: .utf8)

        let items = DictationHistory.load(recordings: recordings, historyFile: historyFile)
        #expect(items.map(\.bestText) == ["", "Hello there.", "Only in the history."])
        #expect(items.map(\.outcome) == [.nothingTyped, .typed, .typed])
        #expect(items[1].recordingID == typed)
        #expect(items[1].audioURL?.lastPathComponent == "\(typed).wav")
        #expect(items[1].durationSec == 1)
        #expect(items[1].screenshots.isEmpty)  // deleted after 7 days
        #expect(items[2].recordingID == nil)
        #expect(items[2].audioURL == nil)
        // Reading never rewrites the history file.
        #expect(try String(contentsOf: historyFile, encoding: .utf8) == lines.joined(separator: "\n") + "\n")
    }

    @Test func aFixAndATranscribeAgainShowInsteadOfTheTypedText() {
        var item = HistoryItem(id: "x", recordingID: "x", date: Date(), text: "", outcome: .nothingTyped, durationSec: 1, audioURL: nil,
                               screenshots: [], correctedText: nil, retranscribedText: "maybe this", recovered: false)
        #expect(item.bestText == "maybe this")
        item.text = "typed"
        #expect(item.bestText == "typed")
        item.correctedText = "what I said"
        #expect(item.bestText == "what I said")
    }

    @Test func fixItLabelsTheRecordingAndKeepsACopy() throws {
        let dir = try temporaryDirectory("labels")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RecordingArchive(directory: dir.appendingPathComponent("recordings"))
        let id = try archive.save(speech(1), sampleRate: sampleRate, metadata: [])
        let labelled = dir.appendingPathComponent("labelled")
        try DictationLabels.save("  Close mine then. ", for: id, archive: archive, labelled: labelled)
        #expect(archive.entry(id)?["corrected_text"]?.stringValue == "Close mine then.")
        let copy = try OrderedJSONParser.parse(Data(contentsOf: labelled.appendingPathComponent("\(id).json")))
        #expect(copy["corrected_text"]?.stringValue == "Close mine then.")
        #expect(try Data(contentsOf: labelled.appendingPathComponent("\(id).wav")) == RecordingArchive.wavData(speech(1), sampleRate: sampleRate))
        // A second fix replaces the first.
        try DictationLabels.save("Close mine, then.", for: id, archive: archive, labelled: labelled)
        let again = try OrderedJSONParser.parse(Data(contentsOf: labelled.appendingPathComponent("\(id).json")))
        #expect(again["corrected_text"]?.stringValue == "Close mine, then.")
    }
}

struct SettingsEditTests {
    @Test func theWordListIsTrimmedWithoutBlanksOrRepeats() {
        var file = SettingsFile(url: URL(fileURLWithPath: "/tmp/x.json"), json: .object([("microphone_name", .string("Yeti"))]))
        #expect(file.vocabularyWords == VoiceTypeSettings.defaultVocabulary)
        file.setVocabulary([" Convex ", "", "Tandem", "Convex", "  "])
        #expect(file.vocabularyWords == ["Convex", "Tandem"])
        #expect(file.json["vocabulary"] == .strings(["Convex", "Tandem"]))
        // Other keys keep their place.
        #expect(file.json.objectPairs?.map(\.key) == ["microphone_name", "vocabulary"])
    }

    @Test func correctionsKeepTheirOrderAndDropBlanksAndRepeats() {
        var file = SettingsFile(url: URL(fileURLWithPath: "/tmp/x.json"), json: .object([]))
        #expect(file.correctionPairs.map(\.heard) == ["Q DA", "Kuda"])
        file.setCorrections([("Kuda", "CUDA"), (" ", "nothing"), ("tandum", " Tandem "), ("Kuda", "Cuda")])
        #expect(file.json["corrections"] == .object([("Kuda", .string("CUDA")), ("tandum", .string("Tandem"))]))
        #expect(file.dictation.corrections.apply("tandum and kuda") == "Tandem and CUDA")
    }

    @Test func theWindowsWordEditsKeepWordsAddedFromOutside() {
        var file = SettingsFile(url: URL(fileURLWithPath: "/tmp/x.json"), json: .object([("vocabulary", .strings(["Convex", "Claude", "Tailscale"]))]))
        // The window opened with Convex and Claude; Tailscale was added by hand since. The
        // window took out Claude and added Tandem.
        file.applyVocabularyEdit(from: ["Convex", "Claude"], to: ["Convex", "Tandem"])
        #expect(file.vocabularyWords == ["Convex", "Tailscale", "Tandem"])
        // With nothing changed outside, the window's list is saved as it is, order and all.
        file.applyVocabularyEdit(from: ["Convex", "Tailscale", "Tandem"], to: ["Tandem", "Convex"])
        #expect(file.vocabularyWords == ["Tandem", "Convex"])
    }

    @Test func theWindowsCorrectionEditsKeepOnesAddedFromOutside() {
        var file = SettingsFile(url: URL(fileURLWithPath: "/tmp/x.json"), json: .object([
            ("corrections", .object([("Kuda", .string("CUDA")), ("tandum", .string("Tandem")), ("conveks", .string("Convex"))])),
        ]))
        // Opened with Kuda and tandum; conveks came from outside. The window changed tandum,
        // removed Kuda and added clawed.
        file.applyCorrectionsEdit(from: [("Kuda", "CUDA"), ("tandum", "Tandem")], to: [("tandum", "Tandem app"), ("clawed", "Claude")])
        #expect(file.json["corrections"] == .object([("tandum", .string("Tandem app")), ("conveks", .string("Convex")), ("clawed", .string("Claude"))]))
    }

    @Test func retiredPythonKeysAreRemovedAndTheRestKept() throws {
        let dir = try temporaryDirectory("settings")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        var file = SettingsFile(url: url, json: .object([
            ("final_model", .string("large-v3-turbo")), ("microphone_name", .string("Yeti Stereo Microphone")),
            ("output_mode", .string("final_only")), ("formatter_enabled", .bool(false)), ("formatter_system_prompt", .string("...")),
            ("draw_on_screen_enabled", .bool(true)),
        ]))
        #expect(file.removeRetiredKeys() == ["final_model", "output_mode", "formatter_enabled", "formatter_system_prompt"])
        try file.save()
        let reread = SettingsFile.load(from: url)
        #expect(reread.json.objectPairs?.map(\.key) == ["microphone_name", "draw_on_screen_enabled"])
        var again = reread
        #expect(again.removeRetiredKeys().isEmpty)
    }
}

struct RecoveredPillTests {
    @Test func saysWhereTheRecoveredDictationWent() {
        let one = PillAppearance(state: .recovered, text: "A 68 s dictation is in History")
        #expect(one.label == " Recovered")
        #expect(one.color == .green)
        #expect(one.wideLabel)
        let surface = PillTests.Surface()
        let clock = ManualExecutor()
        let pill = PillController(surface: surface, scheduler: clock, now: { clock.now }, reduceMotion: { false })
        pill.showRecovered(count: 1, seconds: 67.6)
        #expect(surface.presented.last?.preview == "A 68 s dictation is in History")
        pill.showRecovered(count: 2, seconds: 90)
        #expect(surface.presented.last?.preview == "2 dictations are in History")
    }
}

struct CapCountdownTests {
    @Test func thePillCountsDownTheLastTenSecondsBeforeTheCap() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(speech(2))
        h.executor.advance(109.5)
        #expect(!h.pill.calls.contains { $0.hasPrefix("left:") })
        h.executor.advance(1)
        #expect(h.pill.calls.filter { $0.hasPrefix("left:") } == ["left:10"])
        h.executor.advance(9.5)
        #expect(h.pill.calls.filter { $0.hasPrefix("left:") } == (1...10).reversed().map { "left:\($0)" })
        #expect(h.logs.contains("--- Recording exceeded 120s safety cap; force-stopping ---"))
    }

    @Test func aDictationThatEndsFirstStopsTheCountdown() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(speech(2))
        h.executor.advance(112)
        h.release()
        let before = h.pill.calls.filter { $0.hasPrefix("left:") }.count
        h.executor.advance(30)
        #expect(h.pill.calls.filter { $0.hasPrefix("left:") }.count == before)
        // And the next dictation starts with REC, not the old count.
        h.press()
        #expect(!h.pill.calls.suffix(2).contains { $0.hasPrefix("left:") })
    }

    @Test func theLabelSaysTheSecondsLeftUntilTheNextRecording() {
        let surface = PillTests.Surface()
        let clock = ManualExecutor()
        let pill = PillController(surface: surface, scheduler: clock, now: { clock.now }, reduceMotion: { false })
        pill.showRecording("hello")
        pill.showSecondsLeft(9)
        #expect(surface.presented.last?.label == " 9s")
        #expect(surface.presented.last?.preview == "hello")
        // A preview update keeps the count.
        pill.showRecording("hello there")
        #expect(surface.presented.last?.label == " 9s")
        pill.showProcessing("hello there")
        pill.hide()
        pill.showRecording("")
        #expect(surface.presented.last?.label == " REC")
        // Not while it isn't recording.
        pill.showProcessing("")
        pill.showSecondsLeft(3)
        #expect(surface.presented.last?.label == " ...")
    }
}

struct FinishedCountTests {
    @Test func eachFinishedDictationBumpsTheCount() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        #expect(h.controller.snapshot.dictationsFinished == 0)
        h.dictate(speech(1))
        #expect(h.controller.snapshot.dictationsFinished == 1)
        // Publishing again (a device change, say) doesn't look like a new dictation.
        h.controller.setEnabled(false)
        #expect(h.snapshots.last?.dictationsFinished == 1)
        h.controller.setEnabled(true)
        h.dictate(speech(1))
        #expect(h.snapshots.last?.dictationsFinished == 2)
    }
}
