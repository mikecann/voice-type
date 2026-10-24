import Foundation

public struct TranscriptSegment: Sendable {
    public var text: String
    public var startSec: Double
    public var endSec: Double
    public var noSpeechProb: Double
    /// Probabilities of the segment's text tokens, for the vote work in phase 4.
    public var tokenProbs: [Double]

    public init(text: String, startSec: Double, endSec: Double, noSpeechProb: Double, tokenProbs: [Double]) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.noSpeechProb = noSpeechProb
        self.tokenProbs = tokenProbs
    }
}

public struct Transcript: Sendable {
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    /// Segment texts stripped and joined with spaces, as voice-type.py's transcribe() does.
    public var text: String {
        PythonText.strip(segments.map { PythonText.strip($0.text) }.filter { !$0.isEmpty }.joined(separator: " "))
    }
}

public struct TranscribeOptions: Sendable {
    /// The word list prompt, already tokenized. Empty means no prompt.
    public var promptTokens: [Int32]
    /// 0 for greedy decoding, which is what the app uses; above 0 is beam search.
    public var beamSize: Int

    public init(promptTokens: [Int32] = [], beamSize: Int = 0) {
        self.promptTokens = promptTokens
        self.beamSize = beamSize
    }
}

/// A speech-to-text engine. whisper.cpp is the only one for now; PLAN.md has the fuller
/// version (load, cancel, unload) the app and the vote will need.
public protocol SpeechEngine: AnyObject {
    func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript
}

public struct DictationResult: Sendable {
    public enum Status: String, Sendable {
        /// The microphone delivered digital silence; nothing transcribed.
        case flatlineCapture = "flatline_capture"
        /// Short and near-silent; nothing transcribed.
        case skippedLowLevel = "skipped_low_level"
        /// Under 0.3 s; Whisper isn't asked.
        case tooShort = "too_short"
        /// Whisper ran but nothing was left to type.
        case finishedWithoutText = "finished_without_text"
        case completed

        /// The status the Python app writes to a recording's JSON for the same outcome.
        public var pythonStatus: String {
            self == .tooShort ? "finished_without_text" : rawValue
        }
    }

    public var status: Status
    public var levels: AudioLevels
    /// What Whisper said, before the loop guard and corrections. Nil when it didn't run.
    public var rawTranscript: String?
    /// What would be typed. Empty when nothing would be.
    public var text: String
    public var transcript: Transcript?

    public init(status: Status, levels: AudioLevels, rawTranscript: String? = nil, text: String, transcript: Transcript? = nil) {
        self.status = status
        self.levels = levels
        self.rawTranscript = rawTranscript
        self.text = text
        self.transcript = transcript
    }
}

/// Everything between key-up and typing, in the order voice-type.py does it: the flatline and
/// near-silence gates, the 0.3 s minimum, Whisper, the repetition loop guard, corrections.
public struct DictationPipeline {
    public var engine: SpeechEngine
    public var settings: VoiceTypeSettings
    public var options: TranscribeOptions

    public init(engine: SpeechEngine, settings: VoiceTypeSettings, options: TranscribeOptions) {
        self.engine = engine
        self.settings = settings
        self.options = options
    }

    public func run(_ samples: [Float]) throws -> DictationResult {
        let levels = AudioLevels(samples: samples)
        if AudioGate.isFlatlineAudioCapture(durationSec: levels.durationSec, rms: levels.rms, peak: levels.peak) {
            return DictationResult(status: .flatlineCapture, levels: levels, text: "")
        }
        if AudioGate.shouldSkipShortLowLevelAudio(durationSec: levels.durationSec, rms: levels.rms, peak: levels.peak) {
            return DictationResult(status: .skippedLowLevel, levels: levels, text: "")
        }
        // Anything shorter is a stray tap that slipped past the level gate.
        if levels.durationSec < 0.3 {
            return DictationResult(status: .tooShort, levels: levels, text: "")
        }
        let transcript = try engine.transcribe(samples, options: options)
        let raw = transcript.text
        let guarded = RepetitionLoopGuard.guardLoops(raw, durationSec: levels.durationSec)
        let text = settings.corrections.apply(guarded)
        return DictationResult(
            status: text.isEmpty ? .finishedWithoutText : .completed,
            levels: levels,
            rawTranscript: raw,
            text: text,
            transcript: transcript
        )
    }

    /// Whisper alone, still with the word list prompt since that's part of how it decodes.
    /// This is what the parity runs compare with the benchmark's whisper.cpp text.
    public func runEngineOnly(_ samples: [Float]) throws -> DictationResult {
        let transcript = try engine.transcribe(samples, options: options)
        return DictationResult(
            status: transcript.text.isEmpty ? .finishedWithoutText : .completed,
            levels: AudioLevels(samples: samples),
            rawTranscript: transcript.text,
            text: transcript.text,
            transcript: transcript
        )
    }
}
