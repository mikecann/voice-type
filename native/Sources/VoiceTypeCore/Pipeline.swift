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
        /// A second or more that never got louder than the room, which Whisper turned into
        /// one of its silence phrases ("Thank you."); nothing typed. Native only: see
        /// AudioGate.isLongNearSilentClip and isSilenceHallucination.
        case skippedNearSilent = "skipped_near_silent"
        /// Under 0.3 s; Whisper isn't asked.
        case tooShort = "too_short"
        /// Whisper ran but nothing was left to type.
        case finishedWithoutText = "finished_without_text"
        case completed

        /// The status the Python app writes to a recording's JSON for the same outcome. The
        /// near-silence gate's skips are recorded like the short-clip gate's, since they're
        /// the same kind of outcome to anything reading the archive.
        public var pythonStatus: String {
            switch self {
            case .tooShort: return "finished_without_text"
            case .skippedNearSilent: return "skipped_low_level"
            default: return rawValue
            }
        }

        /// True when a gate kept the clip from Whisper.
        public var wasGated: Bool { self == .flatlineCapture || self == .skippedLowLevel || self == .tooShort }
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
/// Native adds one check after Whisper, for silent clips of a second or more that it turned
/// into "Thank you.".
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
        if let gated = Self.gate(levels) { return gated }
        return try transcribe(samples, levels: levels)
    }

    /// The gates on their own, in order. Nil means the clip goes to Whisper.
    public static func gate(_ levels: AudioLevels) -> DictationResult? {
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
        return nil
    }

    /// Whisper, the loop guard and corrections, for a clip the gates let through. A clip of a
    /// second or more that stayed near silent is dropped here if Whisper only produced one of
    /// its silence phrases, so a quiet real "Sure." still gets typed.
    public func transcribe(_ samples: [Float], levels: AudioLevels) throws -> DictationResult {
        let transcript = try engine.transcribe(samples, options: options)
        let raw = transcript.text
        let guarded = RepetitionLoopGuard.guardLoops(raw, durationSec: levels.durationSec)
        if AudioGate.isLongNearSilentClip(durationSec: levels.durationSec, peak: levels.peak) && AudioGate.isSilenceHallucination(guarded) {
            return DictationResult(status: .skippedNearSilent, levels: levels, rawTranscript: raw, text: "", transcript: transcript)
        }
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
