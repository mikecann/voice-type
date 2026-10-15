"""Local audio and diagnostic metadata with time-based retention."""

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import struct
import threading
import uuid

import numpy as np


_RECORDING_FILE = re.compile(r'^(\d{8}T\d{12}Z)_[0-9a-f]{32}\.(wav|json)(\.tmp)?$')


class RecordingArchive:
    def __init__(self, path, *, retention_days=30, clock=None):
        self.path = Path(path)
        self.retention_days = retention_days
        self._clock = clock or (lambda: datetime.now(timezone.utc))
        self._lock = threading.Lock()

    def save(self, audio, *, sample_rate, metadata):
        now = self._clock().astimezone(timezone.utc)
        recording_id = f'{now.strftime("%Y%m%dT%H%M%S%fZ")}_{uuid.uuid4().hex}'
        # Float WAV preserves the actual samples Whisper receives. PCM16 would
        # introduce quantization when replaying a quiet or misheard recording.
        samples = np.asarray(audio, dtype='<f4').reshape(-1)
        data = samples.tobytes()
        fmt = struct.pack('<HHIIHH', 3, 1, sample_rate, sample_rate * 4, 4, 32)
        chunks = (
            b'fmt ' + struct.pack('<I', len(fmt)) + fmt
            + b'fact' + struct.pack('<II', 4, len(samples))
            + b'data' + struct.pack('<I', len(data)) + data
        )
        wav = b'RIFF' + struct.pack('<I', len(chunks) + 4) + b'WAVE' + chunks
        entry = {
            **metadata,
            'id': recording_id,
            'created_at': now.isoformat(),
            'audio_file': f'{recording_id}.wav',
            'sample_rate': sample_rate,
            'sample_count': len(samples),
            'duration_seconds': len(samples) / sample_rate,
            'status': 'captured',
        }
        with self._lock:
            self.path.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.path.chmod(0o700)
            self._write_atomic(self.path / f'{recording_id}.wav', wav)
            self._write_json(recording_id, entry)
        return recording_id

    def update(self, recording_id, **fields):
        with self._lock:
            path = self.path / f'{recording_id}.json'
            try:
                entry = json.loads(path.read_text(encoding='utf-8'))
            except FileNotFoundError:
                # A late finalizer must not recreate an expired archive entry.
                return
            entry.update(fields)
            self._write_json(recording_id, entry)

    def cleanup(self):
        """Delete expired pairs and interrupted writes, even without metadata.

        Use the UTC capture time in our own filenames, not a mutable file mtime.
        Files unrelated to this archive are never deleted.
        """
        cutoff = self._clock().astimezone(timezone.utc) - timedelta(days=self.retention_days)
        removed = 0
        with self._lock:
            if not self.path.exists():
                return removed
            for path in self.path.iterdir():
                match = _RECORDING_FILE.fullmatch(path.name)
                if not match:
                    continue
                try:
                    created = datetime.strptime(match[1], '%Y%m%dT%H%M%S%fZ').replace(tzinfo=timezone.utc)
                except ValueError:
                    continue
                if created < cutoff:
                    path.unlink(missing_ok=True)
                    removed += 1
        return removed

    def _write_json(self, recording_id, entry):
        self._write_atomic(
            self.path / f'{recording_id}.json',
            (json.dumps(entry, ensure_ascii=False, indent=2) + '\n').encode('utf-8'),
        )

    @staticmethod
    def _write_atomic(path, payload):
        temporary = path.with_suffix(path.suffix + '.tmp')
        try:
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                os.chmod(temporary, 0o600)
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
