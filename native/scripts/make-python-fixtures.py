"""Writes the files the Python app would write, so the Swift tests can compare bytes.

Run from the repo root with: python3 native/scripts/make-python-fixtures.py
It only writes into native/Tests/VoiceTypeCoreTests/Fixtures/python.
"""

from datetime import datetime, timedelta, timezone
import json
import pathlib
import sys
import tempfile
import uuid
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

import numpy as np  # noqa: E402

from recording_archive import RecordingArchive  # noqa: E402
from transcription_history import TranscriptionHistory  # noqa: E402

OUT = ROOT / "native" / "Tests" / "VoiceTypeCoreTests" / "Fixtures" / "python"
OUT.mkdir(parents=True, exist_ok=True)

# A recording with metadata like voice-type.py's, then the updates finalisation makes.
now = datetime(2026, 10, 24, 2, 31, 11, 950600, tzinfo=timezone.utc)
audio = np.array([0.0, -0.1234567, 0.9876543, 1e-7, -1.0, 0.5], dtype=np.float32)
with tempfile.TemporaryDirectory() as tmp:
    archive = RecordingArchive(pathlib.Path(tmp), clock=lambda: now)
    with mock.patch.object(uuid, "uuid4", return_value=uuid.UUID("5b176e01cb8a40ddbd9e2fa3bdf9e8c7")):
        rid = archive.save(audio, sample_rate=16000, metadata={
            "mode": "final_only",
            "final_model": "large-v3-turbo",
            "stream_model": "large-v3-turbo",
            "microphone": "Yeti Stereo Microphone",
            "preferred_microphone": "Yeti Stereo Microphone",
            "key_hold_seconds": 2.361856874951627,
            "capture_ready_delay_seconds": 0.03931699995882809,
            "first_audio_delay_seconds": None,
            "formatter_enabled": False,
            "vocabulary": ["Convex", "Café", "Sammy Cam"],
        })
    (OUT / "recording-captured.json").write_bytes((pathlib.Path(tmp) / f"{rid}.json").read_bytes())
    archive.update(rid, raw_transcript="Hey, I noticed a bit of lag \"quoted\" — ok\ttab",
                   decoded_text="Hey, I noticed a bit of lag.")
    archive.update(rid, text="Hey, I noticed a bit of lag.", status="completed")
    (OUT / "recording.json").write_bytes((pathlib.Path(tmp) / f"{rid}.json").read_bytes())
    (OUT / "recording.wav").write_bytes((pathlib.Path(tmp) / f"{rid}.wav").read_bytes())

    # A whole-second clip, so duration_seconds is a float that Python writes as "2.0".
    with mock.patch.object(uuid, "uuid4", return_value=uuid.UUID("00000000000000000000000000000001")):
        rid2 = archive.save(np.zeros(32000, dtype=np.float32), sample_rate=16000, metadata={})
    (OUT / "recording-empty-metadata.json").write_bytes((pathlib.Path(tmp) / f"{rid2}.json").read_bytes())

    # No microseconds: isoformat() leaves the fraction off.
    whole = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    archive2 = RecordingArchive(pathlib.Path(tmp) / "b", clock=lambda: whole)
    with mock.patch.object(uuid, "uuid4", return_value=uuid.UUID("00000000000000000000000000000002")):
        rid3 = archive2.save(np.zeros(0, dtype=np.float32), sample_rate=16000, metadata={"x": 1})
    (OUT / "recording-whole-second.json").write_bytes((pathlib.Path(tmp) / "b" / f"{rid3}.json").read_bytes())
    (OUT / "recording-whole-second.wav").write_bytes((pathlib.Path(tmp) / "b" / f"{rid3}.wav").read_bytes())

# History lines.
zone = timezone(timedelta(hours=11))
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp) / "transcription-history.jsonl"
    history = TranscriptionHistory(path, clock=lambda: datetime(2026, 10, 24, 13, 31, 11, tzinfo=zone))
    history.append("  First one, with \"quotes\" and café.  ", "final_only")
    history.append("Second \U0001F399 line", "final_only", created_at="2026-10-24T13:32:00+11:00")
    (OUT / "transcription-history.jsonl").write_bytes(path.read_bytes())

# settings.json as _save_settings writes it.
settings = {
    "final_model": "large-v3-turbo",
    "microphone_name": "Yeti Stereo Microphone",
    "corrections": {"Q DA": "CUDA", "Kuda": "CUDA"},
    "vocabulary": ["Convex", "Café"],
    "formatter_system_prompt": "You are a transcription cleaner.\n\nReturn only \"text\".\n",
    "audio_recording_enabled": True,
    "empty": {},
    "list": [],
    "ratio": 0.5,
    "native": {"microphone": "x"},
}
(OUT / "settings.json").write_text(json.dumps(settings, indent=2), encoding="utf-8")
print("wrote", sorted(p.name for p in OUT.iterdir()))
