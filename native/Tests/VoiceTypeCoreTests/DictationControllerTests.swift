import Foundation
import Testing
@testable import VoiceTypeCore

struct DictationControllerStartupTests {
    @Test func becomesReadyOnlyOnceTheMicrophoneAndModelAre() throws {
        let h = try ControllerHarness()
        h.transcriber.loadResult = nil  // the model takes a while
        h.controller.start()
        h.executor.drain()
        #expect(h.phase == .starting)
        #expect(h.probe.probed == [.named("Yeti Stereo Microphone")])
        // The status stays hidden until someone presses the key.
        #expect(h.pill.calls.isEmpty)
        h.press()
        #expect(h.pill.last == "processing:Loading the speech model...")
        #expect(h.factory.events.isEmpty)
        h.transcriber.completeLoad()
        h.executor.drain()
        #expect(h.phase == .idle)
        #expect(h.pill.last == "hide")
        // The stream is opened (not started) ready for key-down.
        #expect(h.factory.events == ["open s1:Yeti Stereo Microphone"])
        #expect(h.watchdogs.map(\.name) == ["model-load"])
        #expect(h.watchdogs[0].timeout == 180)
    }

    @Test func waitsThirtySecondsForTheYetiThenUsesTheDefault() throws {
        let h = try ControllerHarness(devices: [InputDevice(id: 1, name: "MacBook Pro Microphone")])
        h.startAndBecomeReady()
        #expect(h.phase == .idle)
        #expect(h.probe.probed.first == .named("Yeti Stereo Microphone"))
        #expect(h.probe.probed.last == .systemDefault)
        #expect(h.probe.probed.count == 31)
        #expect(h.logs.contains("Preferred microphone 'Yeti Stereo Microphone' was not ready after 30s; trying the system default microphone."))
        #expect(h.recorder.currentSelection == .systemDefault)
    }

    @Test func aProbeOfDigitalSilenceKeepsDictationOff() throws {
        let h = try ControllerHarness(settings: .object([("microphone_name", .string(""))]))
        h.probe.silentProbes = 3
        h.controller.start()
        h.executor.drain()
        #expect(h.logs.contains("Microphone not ready (MacBook Pro Microphone: digital silence); Voice Type will not accept dictation yet."))
        // Logged once, not every second.
        #expect(h.logs.filter { $0.hasPrefix("Microphone not ready") }.count == 1)
        #expect(h.probe.probed == [.systemDefault, .systemDefault, .systemDefault, .systemDefault])
        #expect(h.phase == .idle)
    }

    @Test func aMissingModelWaitsInsteadOfRestarting() throws {
        let h = try ControllerHarness()
        h.transcriber.loadResult = .failure(ModelFileMissing(path: "/x/model.bin"))
        h.startAndBecomeReady()
        #expect(h.phase == .needsModel)
        #expect(h.restarts.isEmpty)
        h.press()
        #expect(h.pill.last == "processing:Speech model missing")
    }

    @Test func aFailedModelLoadRestarts() throws {
        let h = try ControllerHarness()
        h.transcriber.loadResult = .failure(MicrophoneUnavailable("metal"))
        h.startAndBecomeReady()
        #expect(h.restarts == ["Final model failed to load; restarting Voice Type"])
    }
}

struct DictationControllerDictationTests {
    @Test func dictatesSavesRemembersThenPastes() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        var savedBeforeWhisper = false
        h.engine.duringTranscribe = { savedBeforeWhisper = h.recordingEntries().first?["status"] == .string("captured") }
        var historyBeforePaste = false
        h.paster.duringPaste = { historyBeforePaste = (try? h.history.load().first?.text) == "Port it to CUDA." }

        h.press()
        #expect(h.phase == .recording)
        #expect(h.pill.calls == ["hide"])
        #expect(h.factory.events.last == "start s1:Yeti Stereo Microphone")
        h.factory.deliver(ControllerHarness.speech(seconds: 0.4))
        h.executor.drain()
        // REC shows with the first block of audio, not at key-down.
        #expect(h.pill.last == "rec:")
        h.factory.deliver(ControllerHarness.speech(seconds: 1.0))
        h.release()

        #expect(h.phase == .idle)
        #expect(savedBeforeWhisper)
        #expect(historyBeforePaste)
        #expect(h.paster.pasted.map(\.text) == ["Port it to CUDA."])
        #expect(h.paster.pasted.first?.target == TargetApp(pid: 42, name: "T3 Code"))
        #expect(h.pill.calls.suffix(2) == ["processing:", "done:4"])
        #expect(h.transcriber.finalBegun == 1 && h.transcriber.finalEnded == 1)
        // The engine got exactly what the microphone delivered.
        #expect(h.engine.finals.first?.count == Int(1.4 * 16000))

        let entry = try #require(h.recordingEntries().first)
        #expect(entry["status"] == .string("completed"))
        #expect(entry["text"] == .string("Port it to CUDA."))
        #expect(entry["raw_transcript"] == .string("Port it to kuda."))
        #expect(entry["decoded_text"] == .string("Port it to CUDA."))
        #expect(entry["app"] == .string("native"))
        #expect(entry["mode"] == .string("final_only"))
        #expect(entry["microphone"] == .string("Yeti Stereo Microphone"))
        #expect(entry["preferred_microphone"] == .string("Yeti Stereo Microphone"))
        #expect(entry["vocabulary"] == .strings(["Convex"]))
        #expect(entry["duration_seconds"] == .double(1.4))
        #expect(entry["segments"]?.objectPairs == nil)
        guard case let .array(segments)? = entry["segments"] else { Issue.record("no segments"); return }
        #expect(segments.first?["no_speech_prob"] == .double(0.01))
        #expect(entry["timings"]?["key_up_to_paste_seconds"] != nil)
        // Python's keys first, in Python's order, then native's.
        let keys = try #require(entry.objectPairs?.map(\.key))
        #expect(Array(keys.prefix(19)) == ["mode", "final_model", "stream_model", "microphone", "preferred_microphone",
                                           "key_hold_seconds", "capture_ready_delay_seconds", "first_audio_delay_seconds",
                                           "formatter_enabled", "vocabulary", "app", "engine", "id", "created_at", "audio_file",
                                           "sample_rate", "sample_count", "duration_seconds", "status"])
    }

    @Test func aPasteThatDidNotLandPointsAtTheClipboard() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.paster.landed = false
        h.dictate(ControllerHarness.speech(seconds: 1))
        #expect(h.pill.last == "paste_failed")
        #expect(h.recordingEntries().first?["status"] == .string("completed"))
    }

    @Test func aPasteErrorHidesThePillAndRecordsIt() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.paster.throwError = true
        h.dictate(ControllerHarness.speech(seconds: 1))
        #expect(h.pill.last == "hide")
        #expect(h.recordingEntries().first?["status"] == .string("finalization_error"))
        #expect(h.phase == .idle)
    }

    @Test func transcriptionErrorsKeepTheAudioAndTheError() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.engine.fail = true
        h.dictate(ControllerHarness.speech(seconds: 1))
        let entry = try #require(h.recordingEntries().first)
        #expect(entry["status"] == .string("transcription_error"))
        #expect(entry["error"] == .string("whisper failed"))
        #expect(h.paster.pasted.isEmpty)
        #expect(h.pill.last == "hide")
    }

    @Test func recordingOffStillTypesAndRemembers() throws {
        let h = try ControllerHarness(settings: .object([("audio_recording_enabled", .bool(false))]))
        h.startAndBecomeReady()
        h.dictate(ControllerHarness.speech(seconds: 1))
        #expect(h.recordingEntries().isEmpty)
        #expect(try h.history.load().map(\.text) == ["Port it to CUDA."])
        #expect(h.paster.pasted.count == 1)
    }

    @Test func keyDownWhileFinalisingIsIgnored() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.controller.hotkeyChanged(down: false)
        // The finalisation is queued but hasn't run: a quick second press.
        h.controller.hotkeyChanged(down: true)
        h.controller.hotkeyChanged(down: false)
        h.executor.drain()
        #expect(h.logs.contains("Recording ignored while the previous dictation is finalizing."))
        #expect(h.paster.pasted.count == 1)
        #expect(h.factory.events.filter { $0.hasPrefix("start") }.count == 1)
    }

    @Test func aFailedStartNeverFinalisesAnything() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.dictate(ControllerHarness.speech(seconds: 1))
        h.factory.failOpen = true
        h.recorder.invalidate()
        h.press()
        h.release()
        #expect(h.paster.pasted.count == 1)
        #expect(h.logs.contains("--- Key UP ignored: recording never started ---"))
        // It reconnects the microphone rather than restarting.
        #expect(h.restarts.isEmpty)
        #expect(h.logs.contains("Preparing the microphone again (microphone stream could not open)."))
    }

    @Test func theCapStopsAStuckKeyAndWaitsForARealRelease() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 2))
        h.executor.advance(120)
        #expect(h.logs.contains("--- Recording exceeded 120s safety cap; force-stopping ---"))
        #expect(h.paster.pasted.count == 1)
        #expect(h.phase == .idle)
        // The release of the stuck key does nothing; the next press records again.
        h.release()
        #expect(h.phase == .idle)
        h.press()
        #expect(h.phase == .recording)
    }

    @Test func gatedClipsNeverReachWhisper() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        // A 0.2 s tap of room noise.
        h.dictate((0..<3_200).map { Float($0 % 7) * 0.0003 })
        #expect(h.engine.finals.isEmpty)
        #expect(h.paster.pasted.isEmpty)
        let entries = h.recordingEntries()
        #expect(entries.map { $0["status"] } == [.string("skipped_low_level")])
        #expect(entries.first?["skip_reason"] == nil)
    }

    @Test func aLongSilentClipIsDroppedOnlyWhenWhisperHeardThankYou() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        let room = (0..<35_200).map { Float($0 % 7) * 0.0003 }
        // 2.2 s of room noise: the near-silent "Thank you." case.
        h.engine.segments = ["Thank you."]
        h.dictate(room)
        #expect(h.engine.finals.count == 1)
        #expect(h.paster.pasted.isEmpty)
        #expect(h.pill.last == "hide")
        // The same level with real words in it, said quietly.
        h.engine.segments = ["Sure."]
        h.dictate(room)
        #expect(h.paster.pasted.map(\.text) == ["Sure."])
        let entries = h.recordingEntries()
        #expect(entries.map { $0["status"] } == [.string("skipped_low_level"), .string("completed")])
        #expect(entries.first?["skip_reason"] == .string("long_near_silent"))
        #expect(entries.first?["raw_transcript"] == .string("Thank you."))
        #expect(entries.last?["skip_reason"] == nil)
    }

    @Test func aKeyHoldWithNoAudioAtAllReconnectsTheMicrophone() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        // The stream started, but nothing ever arrives.
        h.executor.advance(0.5)
        #expect(h.pill.last == "rec:\(AudioGate.nativeFlatlineRecordingMessage)")
        h.executor.advance(0.7)
        h.release()
        #expect(h.recordingEntries().first?["status"] == .string("flatline_capture"))
        #expect(h.pill.calls.contains("processing:\(AudioGate.nativeFlatlineRecoveryMessage)"))
        #expect(h.logs.contains("No microphone audio arrived during a 1.20s key hold; skipping transcription and reconnecting the microphone."))
        #expect(h.probe.probed.count == 2)
        #expect(h.phase == .idle)
        #expect(h.restarts.isEmpty)
    }

    @Test func aQuickTapWithNoAudioIsJustATap() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.executor.advance(0.3)
        h.release()
        #expect(h.recordingEntries().first?["status"] == .string("skipped_low_level"))
        #expect(h.probe.probed.count == 1)
    }

    @Test func theClipboardNoticeShowsOnceWhenMacOSDeniesTheRead() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.paster.clipboard = .denied
        h.dictate(ControllerHarness.speech(seconds: 1))
        #expect(h.pill.last == "clipboard_not_kept")
        h.dictate(ControllerHarness.speech(seconds: 1))
        #expect(h.pill.last == "done:4")
        #expect(h.logs.filter { $0.hasPrefix("Clipboard access is denied") }.count == 1)
    }

    @Test func underAThirdOfASecondShowsProcessingThenNothing() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.dictate(ControllerHarness.speech(seconds: 0.25))
        #expect(h.engine.finals.isEmpty)
        #expect(h.pill.calls.suffix(2) == ["processing:", "hide"])
        #expect(h.recordingEntries().first?["status"] == .string("finished_without_text"))
    }

    @Test func aFlatlineReconnectsTheMicrophoneInsteadOfRestarting() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.dictate([Float](repeating: 0, count: 16_000))
        #expect(h.recordingEntries().first?["status"] == .string("flatline_capture"))
        #expect(h.restarts.isEmpty)
        #expect(h.pill.calls.contains("processing:\(AudioGate.nativeFlatlineRecoveryMessage)"))
        // Readiness ran again, with its status on screen, and finished.
        #expect(h.probe.probed.count == 2)
        #expect(h.phase == .idle)
        #expect(h.pill.last == "hide")
        #expect(h.factory.events.contains("close s1:Yeti Stereo Microphone"))
    }

    @Test func disabledIgnoresTheKey() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.controller.setEnabled(false)
        h.press()
        #expect(h.phase == .idle)
        h.controller.setEnabled(true)
        h.release()
        h.press()
        #expect(h.phase == .recording)
    }
}

struct DictationControllerPreviewTests {
    @Test func previewsEveryHalfSecondAndAbortsAtKeyUp() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 0.5))
        h.executor.advance(0.5)
        // Under 0.8 s of audio: no preview yet.
        #expect(h.transcriber.previewRequests.isEmpty)
        h.factory.deliver(ControllerHarness.speech(seconds: 0.5))
        h.executor.advance(0.5)
        #expect(h.transcriber.previewRequests.count == 1)
        h.transcriber.releasePreview("one two three four five six seven eight nine ten eleven")
        h.executor.drain()
        #expect(h.pill.last == "rec:one two three four five six\nseven eight nine ten eleven")
        h.executor.advance(0.5)
        #expect(h.transcriber.previewRequests.count == 1)
        h.release()
        #expect(h.transcriber.finalBegun == 1)
        // The final pass shows the last preview while it runs.
        #expect(h.pill.calls.contains("processing:one two three four five six\nseven eight nine ten eleven"))
        // A preview that comes back after key-up is ignored.
        h.transcriber.releasePreview("late")
        h.executor.drain()
        #expect(!h.pill.calls.contains { $0.contains("late") })
    }

    @Test func aStreamOfZerosShowsTheMicrophoneWarningInsteadOfAPreview() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver([Float](repeating: 0, count: 16_000))
        h.executor.advance(0.5)
        #expect(h.transcriber.previewRequests.isEmpty)
        #expect(h.pill.last == "rec:\(AudioGate.nativeFlatlineRecordingMessage)")
    }
}

struct DictationControllerRecoveryTests {
    @Test func aMicrophoneOpenThatHangsRestartsInsteadOfWedgingTheQueue() throws {
        let h = try ControllerHarness()
        h.coreAudioHangs = true
        h.startAndBecomeReady()
        #expect(h.restarts == ["Core Audio hung opening the microphone stream; restarting with a fresh process"])
        #expect(h.phase == .starting)
    }

    @Test func aTimedOutStopAbandonsTheStreamAndNeverClosesIt() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.coreAudioHangs = true
        h.release()
        #expect(h.factory.events.contains("abandon s1:Yeti Stereo Microphone"))
        #expect(!h.factory.events.contains("close s1:Yeti Stereo Microphone"))
        // A wake now must not touch the microphone either: the process restarts first.
        h.controller.systemWoke()
        h.executor.drain()
        #expect(h.factory.events.filter { $0.hasPrefix("open") }.count == 1)
    }

    @Test func aProbeThatHangsAfterAWakeRestarts() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.probe.hangs = true
        h.controller.systemWoke()
        h.executor.drain()
        #expect(h.restarts.count == 1)
        #expect(h.restarts.first?.hasPrefix("starting the probe hung inside Core Audio") == true)
        #expect(h.probe.probed.count == 2)
    }

    @Test func aMicrophoneThatStaysSilentAfterAWakeRestartsAfter45Seconds() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.probe.silentProbes = 1000
        h.controller.systemWoke()
        h.executor.drain()
        #expect(h.restarts.first?.hasPrefix("The microphone gave no audio for 45s after wake") == true)
    }

    @Test func atStartupASilentMicrophoneIsWaitedForAsInPython() throws {
        let h = try ControllerHarness()
        h.probe.silentProbes = 100
        h.startAndBecomeReady()
        #expect(h.restarts.isEmpty)
        #expect(h.phase == .idle)
    }

    @Test func aStuckMicrophoneCheckRestarts() throws {
        let stuck = ManualExecutor()
        let h = try ControllerHarness(readinessLane: stuck)
        h.startAndBecomeReady()
        #expect(h.phase == .starting)
        h.executor.advance(30)
        #expect(h.restarts.isEmpty)
        h.executor.advance(2)
        #expect(h.restarts == ["The microphone check has been stuck for over 30s (Core Audio hung); restarting with a fresh process"])
    }

    @Test func theKeysPassThroughOnlyWhenDictationCannotHappen() throws {
        let h = try ControllerHarness()
        h.transcriber.loadResult = nil
        h.controller.start()
        h.executor.drain()
        // Starting: swallowed, as Python did, so a press explains itself.
        #expect(h.controller.snapshot.swallowsHotkeys)
        h.transcriber.completeLoad()
        h.executor.drain()
        #expect(h.controller.snapshot.swallowsHotkeys)
        h.controller.setEnabled(false)
        #expect(!h.controller.snapshot.swallowsHotkeys)
        let missing = try ControllerHarness()
        missing.transcriber.loadResult = .failure(ModelFileMissing(path: "/x"))
        missing.startAndBecomeReady()
        #expect(!missing.controller.snapshot.swallowsHotkeys)
    }
}

struct DictationControllerSystemTests {
    @Test func aWakeMidDictationWaitsThenRebuildsAndWarmsUp() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.controller.systemWoke()
        h.executor.drain()
        #expect(h.phase == .recording)
        h.release()
        // The dictation finished first, then audio was rebuilt and the model warmed.
        #expect(h.paster.pasted.count == 1)
        #expect(h.phase == .idle)
        #expect(h.watchdogs.map(\.name) == ["model-load", "finalization", "wake-warm-up"])
        #expect(h.watchdogs.last?.timeout == 10)
        #expect(h.engine.finals.last?.count == 8000)
        #expect(h.probe.probed.count == 2)
        #expect(h.restarts.isEmpty)
    }

    @Test func aFailedWarmUpRestarts() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.transcriber.warmUpFails = true
        h.controller.systemWoke()
        h.executor.drain()
        #expect(h.restarts == ["The warm-up pass after wake failed; restarting with a fresh Metal backend"])
    }

    @Test func aBigWallClockGapCountsAsAWake() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.wall = h.wall.addingTimeInterval(600)
        h.executor.advance(2)
        #expect(h.logs.contains("System resume detected after a 600.0s gap."))
        #expect(h.probe.probed.count == 2)
    }

    @Test func losingTheYetiChecksAgainAndItsReturnSwitchesBack() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        #expect(h.recorder.currentSelection == .named("Yeti Stereo Microphone"))
        h.catalog.devices.removeAll { $0.name.hasPrefix("Yeti") }
        h.controller.audioDevicesChanged()
        h.executor.drain()
        #expect(h.recorder.currentSelection == .systemDefault)
        h.catalog.devices.append(InputDevice(id: 3, name: "Yeti Stereo Microphone"))
        h.controller.audioDevicesChanged()
        h.executor.drain()
        #expect(h.recorder.currentSelection == .named("Yeti Stereo Microphone"))
        #expect(h.phase == .idle)
    }

    @Test func deviceChangesDuringADictationWaitForIt() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.catalog.devices.removeAll { $0.name.hasPrefix("Yeti") }
        h.controller.audioDevicesChanged()
        h.executor.drain()
        #expect(h.phase == .recording)
        h.release()
        #expect(h.paster.pasted.count == 1)
        #expect(h.recorder.currentSelection == .systemDefault)
    }

    @Test func restartWaitsUntilTheDictationIsDone() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        var restarted = false
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.controller.whenIdle("Restarting") { restarted = true }
        #expect(!restarted)
        h.release()
        #expect(restarted)
        #expect(h.paster.pasted.count == 1)
        #expect(h.phase == .stopping)
        // Nothing new starts once it's stopping.
        h.press()
        #expect(h.phase == .stopping)
    }

    @Test func publishesItsStateForTheStatusFile() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        #expect(h.snapshots.last?.phase == .recording)
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.release()
        #expect(h.snapshots.contains { $0.phase == .finalising && $0.finalizeInFlight })
        #expect(h.snapshots.last?.phase == .idle)
        #expect(h.snapshots.last?.lastDictation?.landed == true)
        #expect(h.snapshots.last?.lastDictation?.words == 4)
    }

    @Test func aMicrophoneStartThatHangsRestartsTheProcess() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.coreAudioHangs = true
        h.press()
        #expect(h.restarts == ["microphone stream could not open; relaunching the Core Audio backend"])
        #expect(h.paster.pasted.isEmpty)
    }

    @Test func aStopThatHangsFinishesTheDictationThenRestarts() throws {
        let h = try ControllerHarness()
        h.startAndBecomeReady()
        h.press()
        h.factory.deliver(ControllerHarness.speech(seconds: 1))
        h.executor.drain()
        h.coreAudioHangs = true
        h.release()
        // What was captured before the stop still gets typed, exactly once.
        #expect(h.paster.pasted.count == 1)
        #expect(h.restarts == ["Core Audio capture needs recovery; relaunching before another microphone stream is opened"])
    }
}
