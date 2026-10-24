"""Where native's "[n]" markers land, against where Python's landed, on saved dictations.

Python placed markers with mlx-whisper's word timings; native types with its normal pass and
times the words with a second, DTW pass (`serve --word-timings --dtw`), or with the normal
pass's token timestamps when that isn't there (`--token-timestamps` here checks those). This
reruns both engines over saved recordings, which it only reads, and reports:

  words    how far apart the two engines put the start of the same word
  sweep    a mark finished at every 0.1 s of each clip, placed in the text native typed with
           each engine's timings: how often the marker lands after the same word
  marked   the dictations that really had marks: from where Python put each marker, the time
           range of mark that puts it there, then where native would put a mark from the
           middle of that range

Needs mlx-whisper, so run it with the Python app's runtime, without writing bytecode, after
`swift build -c release` in native/:
    "$HOME/Library/Application Support/Voice Type/.venv/bin/python3" -B native/scripts/marker-check.py [--clips N] [--model PATH] [--token-timestamps] [--json OUT]
"""

import difflib
import glob
import json
import os
import pathlib
import statistics
import struct
import subprocess
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

import screen_marks as sm  # noqa: E402
from speech_backends import MlxWhisperModel, build_vocabulary_prompt  # noqa: E402

DATA = pathlib.Path(os.environ.get("VOICE_TYPE_DATA_DIR") or "~/Library/Application Support/Voice Type").expanduser()
BINARY = ROOT / "native/.build/release/voice-type-native"
MLX = sorted(glob.glob(os.path.expanduser("~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/snapshots/*")))[-1]


def read_wav(path):
    data = pathlib.Path(path).read_bytes()
    i, fmt = 12, None
    while i + 8 <= len(data):
        cid, size = data[i:i + 4], struct.unpack("<I", data[i + 4:i + 8])[0]
        body = data[i + 8:i + 8 + size]
        if cid == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif cid == b"data":
            if fmt[0] == 3:
                audio = np.frombuffer(body, dtype=np.float32)
            else:
                audio = np.frombuffer(body, dtype=np.int16).astype(np.float32) / 32768
            return audio.reshape(-1, fmt[1]).mean(axis=1) if fmt[1] > 1 else audio
        i += 8 + size + (size & 1)
    raise ValueError(f"{path}: no data chunk")


def recordings(extra):
    metas = []
    for path in sorted(glob.glob(str(DATA / "recordings/*.json"))):
        meta = json.loads(pathlib.Path(path).read_text())
        meta["wav"] = str(DATA / "recordings" / meta["audio_file"])
        metas.append(meta)
    marked = [m for m in metas if m.get("mark_count") and m.get("decoded_text")]
    plain = [m for m in reversed(metas) if not m.get("mark_count") and m.get("status") == "completed"
             and m.get("app") != "native" and 2 <= m.get("duration_seconds", 0) <= 25][:extra]
    return marked, plain


def position(final, spoken, words, t):
    """How many of the final text's tokens come before a marker for a mark finished at t."""
    counts = sm.spoken_word_counts([t], words=words, segments=None)
    placed = sm.insert_markers(final, spoken, counts, [999]).split()
    return placed.index("[999]") if "[999]" in placed else next(i for i, w in enumerate(placed) if "[999]" in w)


def main():
    args = sys.argv[1:]
    clips = int(args[args.index("--clips") + 1]) if "--clips" in args else 80
    settings = json.loads((DATA / "settings.json").read_text())
    prompt = build_vocabulary_prompt(settings.get("vocabulary"))
    cmd = [str(BINARY), "serve", "--raw", "--word-timings"]
    if "--model" in args:
        cmd += ["--model", args[args.index("--model") + 1]]
    native = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    json.loads(native.stdout.readline())
    timer = None
    if "--token-timestamps" not in args:
        timer = subprocess.Popen(cmd + ["--dtw"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        json.loads(timer.stdout.readline())
    mlx = MlxWhisperModel(repo_id=MLX)

    def ask(proc, wav):
        proc.stdin.write(json.dumps({"id": wav, "path": wav}) + "\n")
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

    def run_native(wav):
        reply = ask(native, wav)
        timed = ask(timer, wav) if timer else reply
        words = [sm.TimedText(s, e, t) for seg in timed["segments"] for s, e, t in seg.get("words", [])]
        return reply["text"], words

    def run_mlx(wav):
        segments, _ = mlx.transcribe(read_wav(wav), language="en", condition_on_previous_text=False,
                                     initial_prompt=prompt, word_timestamps=True)
        words, _ = sm.timings_from_segments(segments)
        return " ".join(s.text for s in segments), words

    marked, plain = recordings(clips)
    gaps, sweep_same, sweep_near, sweep_total, details = [], 0, 0, 0, []
    for meta in marked + plain:
        native_text, native_words = run_native(meta["wav"])
        mlx_text, mlx_words = run_mlx(meta["wav"])
        if not native_words or not mlx_words:
            continue
        a = [sm._normalize(w.text) for w in native_words]
        b = [sm._normalize(w.text) for w in mlx_words]
        for block in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
            for k in range(block.size):
                gaps.append(abs(native_words[block.a + k].start - mlx_words[block.b + k].start))
        native_spoken = " ".join(w.text for w in native_words)
        mlx_spoken = " ".join(w.text for w in mlx_words)
        duration = meta.get("duration_seconds", 0)
        for t in np.arange(0.05, duration, 0.1):
            ours = position(native_text, native_spoken, native_words, t)
            theirs = position(native_text, mlx_spoken, mlx_words, t)
            sweep_total += 1
            sweep_same += ours == theirs
            sweep_near += abs(ours - theirs) <= 1
        if meta.get("mark_count"):
            final = meta["decoded_text"]
            python_text = meta["text"]
            tokens = python_text.split()
            for n in range(1, meta["mark_count"] + 1):
                label = f"[{n}]"
                if label not in python_text:
                    continue
                before = [w for w in tokens[:next(i for i, w in enumerate(tokens) if label in w)] if not w.startswith("[")]
                want = len(before)
                fits = [t for t in np.arange(-0.5, duration + 0.5, 0.02) if position(final, mlx_spoken, mlx_words, t) == want]
                if not fits:
                    details.append({"id": meta["id"], "mark": n, "result": "mlx rerun can't reproduce Python's spot"})
                    continue
                t = float(np.median(fits))
                got = position(final, native_spoken, native_words, t)
                details.append({"id": meta["id"], "mark": n, "python_after_words": want, "native_after_words": got,
                                "mark_time_range": [round(min(fits), 2), round(max(fits), 2)], "same": got == want})
    native.stdin.close()
    native.wait(timeout=60)

    gaps.sort()
    print(f"words: {len(gaps)} matched words over {len(marked) + len(plain)} clips; start times differ by "
          f"median {statistics.median(gaps) * 1000:.0f} ms, p90 {gaps[int(0.9 * (len(gaps) - 1))] * 1000:.0f} ms")
    print(f"sweep: {sweep_total} mark times; same word {sweep_same / sweep_total:.1%}, within one word {sweep_near / sweep_total:.1%}")
    checked = [d for d in details if "same" in d]
    print(f"marked: {sum(d['same'] for d in checked)} of {len(checked)} markers from {len(marked)} marked dictations land where "
          f"Python put them; {len(details) - len(checked)} couldn't be reproduced")
    for d in checked:
        if not d["same"]:
            print(f"  {d['id']} [{d['mark']}]: Python after {d['python_after_words']} words, native after {d['native_after_words']} "
                  f"(mark between {d['mark_time_range'][0]} and {d['mark_time_range'][1]} s)")
    if "--json" in args:
        pathlib.Path(args[args.index("--json") + 1]).write_text(json.dumps({"gaps": gaps, "details": details}, indent=1))


if __name__ == "__main__":
    main()
