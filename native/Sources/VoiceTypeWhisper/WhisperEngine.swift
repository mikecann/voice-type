import Foundation
import VoiceTypeCore
import whisper

public enum WhisperEngineError: LocalizedError, CustomStringConvertible {
    case modelMissing(String)
    case loadFailed(String)
    case decodeFailed(Int32)
    case aborted

    public var description: String {
        switch self {
        case let .modelMissing(path): return "no model at \(path) (pass --model PATH)"
        case let .loadFailed(path): return "whisper.cpp could not load \(path)"
        case let .decodeFailed(rc): return "whisper_full returned \(rc)"
        case .aborted: return "the transcription was stopped part way"
        }
    }

    public var errorDescription: String? { description }
}

/// whisper.cpp large-v3-turbo on Metal, decoding exactly as the benchmark's whispercpp-bench
/// does, since that's the configuration the benchmark measured (its wcpp-q8-vocab key).
///
/// Not thread-safe: one thread owns a context, which is also the plan for the app.
public final class WhisperEngine: DictationEngine {
    private let context: OpaquePointer
    public let threads: Int32
    public let loadMilliseconds: Double

    public init(modelPath: String, useGPU: Bool = true, threads: Int32 = 4) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw WhisperEngineError.modelMissing(modelPath)
        }
        // whisper.cpp logs to stderr by default; the CLI's stdout carries results, and the
        // app will have its own log, so keep it quiet.
        whisper_log_set({ _, _, _ in }, nil)
        let started = DispatchTime.now()
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperEngineError.loadFailed(modelPath)
        }
        self.context = context
        self.threads = threads
        self.loadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
    }

    deinit {
        whisper_free(context)
    }

    /// Tokenizes like mlx-whisper, from the ranks in this model file. See WhisperBPETokenizer.
    public private(set) lazy var tokenizer: WhisperBPETokenizer = makeTokenizer()

    /// The ordinary text tokens' bytes and ids, which double as tiktoken's merge ranks.
    private func makeTokenizer() -> WhisperBPETokenizer {
        var ranks: [[UInt8]: Int32] = [:]
        let eot = whisper_token_eot(context)
        for id in 0..<eot {
            guard let cString = whisper_token_to_str(context, id) else { continue }
            // Token text is raw bytes, often not valid UTF-8 on its own, so don't make a
            // String of it. (The one token for a zero byte comes back empty and is skipped.)
            let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self), count: strlen(cString)))
            if !bytes.isEmpty, ranks[bytes] == nil { ranks[bytes] = id }
        }
        return WhisperBPETokenizer(ranks: ranks)
    }

    /// whisper.cpp's own tokenizer, kept to compare against tiktoken's. See WhisperBPETokenizer.
    public func whisperCppTokenize(_ text: String) -> [Int32] {
        var tokens = [whisper_token](repeating: 0, count: 1024)
        var n = whisper_tokenize(context, text, &tokens, Int32(tokens.count))
        if n < 0 {
            tokens = [whisper_token](repeating: 0, count: Int(-n))
            n = whisper_tokenize(context, text, &tokens, Int32(tokens.count))
        }
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    /// Prompt tokens for the word list, the way mlx-whisper made them for the benchmark.
    public func promptTokens(for prompt: String?) -> [Int32] {
        guard let prompt else { return [] }
        return tokenizer.encode(VocabularyPrompt.tokenizerInput(for: prompt))
    }

    public func transcribe(_ samples: [Float], options: TranscribeOptions) throws -> Transcript {
        try transcribe(samples, options: options, abort: nil)
    }

    /// `abort` is only ever set for live previews. whisper.cpp asks it before the encoder
    /// starts and before each ggml computation, so a key-up stops a running preview within
    /// one step and the final pass goes next. With no flag the parameters are exactly the
    /// benchmarked ones.
    public func transcribe(_ samples: [Float], options: TranscribeOptions, abort: AbortFlag?) throws -> Transcript {
        // Matched to how voice-type calls mlx_whisper.transcribe, via whispercpp-bench:
        // English, temperature 0 with fallback in steps of 0.2, timestamps on, nothing
        // carried over from earlier calls, suppress_blank and non-speech tokens, max initial
        // timestamp 1 s. whisper.cpp's repetition check is an entropy threshold rather than
        // mlx's compression ratio.
        let beam = options.beamSize
        var p = whisper_full_default_params(beam > 0 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY)
        p.n_threads = threads
        p.no_context = true
        p.no_timestamps = false
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.temperature = 0
        p.temperature_inc = 0.2
        p.max_initial_ts = 1.0
        p.entropy_thold = 2.4
        p.logprob_thold = -1.0
        p.no_speech_thold = 0.6
        p.detect_language = false
        if beam > 0 { p.beam_search.beam_size = Int32(beam) }
        // Past 30 s, Python transcribes each window-sized piece separately (split_at_pauses)
        // because mlx only gives the first window the word list. carry_initial_prompt gives
        // every window the word list. whisper.cpp still feeds each window the previous one's
        // text too, even with no_context. Cutting that out (n_max_text_ctx at the prompt's
        // length) moved further from the Python app's text on the 104 saved dictations over
        // 30 s: 2.99% of words differed, against 2.60% with it left in (24 October 2026).
        // Clips under 30 s are one window and get the same prompt either way, so this
        // changes nothing the benchmark measured.
        p.carry_initial_prompt = true

        if let abort {
            let flag = Unmanaged.passUnretained(abort).toOpaque()
            p.abort_callback = { data in
                Unmanaged<AbortFlag>.fromOpaque(data!).takeUnretainedValue().isSet
            }
            p.abort_callback_user_data = flag
            p.encoder_begin_callback = { _, _, data in
                !Unmanaged<AbortFlag>.fromOpaque(data!).takeUnretainedValue().isSet
            }
            p.encoder_begin_callback_user_data = flag
        }

        let rc: Int32 = "en".withCString { language in
            p.language = language
            return options.promptTokens.withUnsafeBufferPointer { prompt in
                p.prompt_tokens = prompt.isEmpty ? nil : prompt.baseAddress
                p.prompt_n_tokens = Int32(prompt.count)
                return samples.withUnsafeBufferPointer { audio in
                    whisper_full(context, p, audio.baseAddress, Int32(audio.count))
                }
            }
        }
        // The flag stays alive for the whole call: the caller holds it.
        withExtendedLifetime(abort) {}
        if abort?.isSet == true { throw WhisperEngineError.aborted }
        guard rc == 0 else { throw WhisperEngineError.decodeFailed(rc) }

        let eot = whisper_token_eot(context)
        var segments: [TranscriptSegment] = []
        for i in 0..<whisper_full_n_segments(context) {
            var probs: [Double] = []
            for j in 0..<whisper_full_n_tokens(context, i) {
                let token = whisper_full_get_token_data(context, i, j)
                if token.id < eot { probs.append(Double(token.p)) }
            }
            segments.append(TranscriptSegment(
                text: String(cString: whisper_full_get_segment_text(context, i)),
                // whisper.cpp counts time in 10 ms steps.
                startSec: Double(whisper_full_get_segment_t0(context, i)) / 100,
                endSec: Double(whisper_full_get_segment_t1(context, i)) / 100,
                noSpeechProb: Double(whisper_full_get_segment_no_speech_prob(context, i)),
                tokenProbs: probs
            ))
        }
        return Transcript(segments: segments)
    }
}
