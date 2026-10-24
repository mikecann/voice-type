#!/usr/bin/env python3
"""Run voice-type-native over the benchmark's labelled clips and compare with whisper.cpp.

Usage (standard library only):
    python3 native/scripts/parity.py BENCHMARK_DIR OUT_DIR [--model PATH] [--raw] [--word-timings]

Talks to `voice-type-native serve` the way the benchmark talks to whispercpp-bench, without
prompt_tokens, so the word list is read from settings.json and tokenized natively. Two sets:

  real     real/items.json + real/agreed.json, compared with real/short/wcpp-q8-vocab.json
  review   review-2026-10-20/items.json + agreed.json, compared with each clip's "parakeet"
           field, which holds whisper.cpp q8_0's text in that batch

Writes OUT_DIR/{real,review}-{raw,pipeline}.json (clip id -> text) and a .meta.json beside
each with status, levels and timings. Reads the benchmark folder, never writes to it.

--word-timings times every word, as the app does for dictations with screen marks, to show
that it doesn't change the text. Its files end in -timed.json.
"""

import json
import statistics
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BINARY = HERE.parent / ".build/release/voice-type-native"


def clips(bench: Path, name: str):
    folder = bench / ("real" if name == "real" else "review-2026-10-20")
    items = json.loads((folder / "items.json").read_text()) + json.loads((folder / "agreed.json").read_text())
    if name == "real":
        reference = json.loads((folder / "short/wcpp-q8-vocab.json").read_text())
    else:
        reference = {item["id"]: item["parakeet"] for item in items}
    return [(item["id"], folder / item["audio"], reference.get(item["id"])) for item in items]


def main():
    args = sys.argv[1:]
    bench, out = Path(args[0]), Path(args[1])
    raw = "--raw" in args
    timed = "--word-timings" in args
    cmd = [str(BINARY), "serve"] + (["--raw"] if raw else []) + (["--word-timings"] if timed else [])
    if "--model" in args:
        cmd += ["--model", args[args.index("--model") + 1]]
    out.mkdir(parents=True, exist_ok=True)

    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

    def ask(request):
        proc.stdin.write(json.dumps(request) + "\n")
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

    ready = json.loads(proc.stdout.readline())
    print(f"ready in {ready['load_ms']:.0f} ms, pid {ready['pid']}", flush=True)
    # One warm-up pass, as run_set.py does, so the first clip's time isn't Metal's setup.
    first = clips(bench, "real")[0][1]
    ask({"id": "warm-up", "path": str(first)})

    mode = ("raw" if raw else "pipeline") + ("-timed" if timed else "")
    for name in ("real", "review"):
        texts, meta, same, different, times = {}, {}, 0, [], []
        for clip_id, wav, reference in clips(bench, name):
            reply = ask({"id": clip_id, "path": str(wav)})
            if reply.get("error"):
                raise SystemExit(f"{clip_id}: {reply['error']}")
            texts[clip_id] = reply["text"]
            meta[clip_id] = {k: v for k, v in reply.items() if k not in ("id", "text")}
            if reply["ms"]:
                times.append(reply["ms"])
            if reply["text"] == reference:
                same += 1
            else:
                different.append((clip_id, reference, reply["text"], reply.get("status")))
        (out / f"{name}-{mode}.json").write_text(json.dumps(texts, indent=1, ensure_ascii=False))
        (out / f"{name}-{mode}.meta.json").write_text(json.dumps(meta, indent=1, ensure_ascii=False))
        times.sort()
        p90 = times[int(round(0.9 * (len(times) - 1)))] if times else 0
        print(f"\n{name} ({mode}): {same} identical, {len(different)} different of {len(texts)}; "
              f"whisper ms median {statistics.median(times) if times else 0:.0f}, p90 {p90:.0f}")
        for clip_id, reference, text, status in different:
            print(f"  {clip_id} [{status}]\n    whisper.cpp: {reference!r}\n    native:      {text!r}")
    proc.stdin.close()
    proc.wait(timeout=60)


if __name__ == "__main__":
    main()
