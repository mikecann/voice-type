from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import struct
import tempfile
import unittest

import numpy as np

from recording_archive import RecordingArchive
import ast
import threading
from unittest import mock


class RecordingArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.now = datetime(2026, 10, 14, 2, 0, tzinfo=timezone.utc)
        self.root = Path(self.temp.name) / 'recordings'
        self.archive = RecordingArchive(self.root, clock=lambda: self.now)

    def test_saves_exact_float_audio_and_links_transcript_without_changing_samples(self):
        audio = np.array([0.0, -0.1234567, 0.9876543], dtype=np.float32)
        recording_id = self.archive.save(audio, sample_rate=16000, metadata={'microphone': 'Yeti'})
        self.archive.update(recording_id, text='Yes please.', status='completed')
        metadata = json.loads((self.root / f'{recording_id}.json').read_text())
        wav = (self.root / metadata['audio_file']).read_bytes()
        self.assertEqual(b'RIFF', wav[:4])
        self.assertEqual(3, struct.unpack_from('<H', wav, 20)[0])  # IEEE float WAV.
        self.assertEqual(len(wav) - 8, struct.unpack_from('<I', wav, 4)[0])
        data_start = wav.index(b'data') + 8
        np.testing.assert_array_equal(audio, np.frombuffer(wav[data_start:], dtype='<f4'))
        self.assertEqual('Yes please.', metadata['text'])
        self.assertEqual('Yeti', metadata['microphone'])
        self.assertEqual(len(audio), metadata['sample_count'])

    def test_retains_every_capture_including_empty_audio_without_entry_limit(self):
        ids = [self.archive.save(np.zeros(0, dtype=np.float32), sample_rate=16000, metadata={}) for _ in range(3)]
        self.assertEqual(3, len(set(ids)))
        self.assertEqual(3, len(list(self.root.glob('*.wav'))))

    def test_cleanup_expires_audio_metadata_and_orphans_by_recording_time(self):
        old = self.archive.save(np.zeros(1), sample_rate=16000, metadata={})
        self.now += timedelta(days=30)
        self.archive.cleanup()
        self.assertTrue((self.root / f'{old}.wav').exists())
        fresh = self.archive.save(np.zeros(1), sample_rate=16000, metadata={})
        (self.root / f'{old}.json').unlink()  # Interrupted write or missing metadata.
        unrelated = self.root / 'keep.txt'
        unrelated.write_text('unrelated')
        self.now += timedelta(seconds=1)
        self.archive.cleanup()
        self.assertFalse((self.root / f'{old}.wav').exists())
        self.assertTrue((self.root / f'{fresh}.wav').exists())
        self.assertTrue(unrelated.exists())

    def test_files_are_owner_only_and_no_temporary_files_remain(self):
        recording_id = self.archive.save(np.zeros(1), sample_rate=16000, metadata={})
        self.archive.update(recording_id, text='Okay.')
        import os
        if os.name != 'nt':
            self.assertEqual(0o700, self.root.stat().st_mode & 0o777)
            for suffix in ('wav', 'json'):
                self.assertEqual(0o600, (self.root / f'{recording_id}.{suffix}').stat().st_mode & 0o777)
        self.assertFalse(list(self.root.glob('*.tmp')))

    def test_late_completion_does_not_recreate_an_expired_recording(self):
        recording_id = self.archive.save(np.zeros(1), sample_rate=16000, metadata={})
        self.now += timedelta(days=31)
        self.archive.cleanup()
        self.archive.update(recording_id, text='Late result')
        self.assertFalse(list(self.root.glob('*.json')))


class RecordingArchiveIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'recordings'
        self.archive = RecordingArchive(self.root)
        self.log = mock.Mock()
        # Load real finalization helpers without opening the GUI, microphone,
        # hotkeys or model. The archive itself still writes real files.
        tree = ast.parse((Path(__file__).resolve().parents[1] / 'voice-type.py').read_text())
        names = {'_update_recording', '_save_recording', '_run_archived_finalization'}
        selected = ast.Module(body=[node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names], type_ignores=[])
        self.ns = {
            '_settings': {'audio_recording_enabled': True},
            '_recording_archive': self.archive,
            '_recording_context': threading.local(),
            '_inference_scheduler': mock.Mock(),
            '_complete_finalization': mock.Mock(),
            'SAMPLE_RATE': 16000,
            'log': self.log,
        }
        exec(compile(selected, 'voice-type.py', 'exec'), self.ns)
        self.watchdog = mock.Mock()

    def finish(self, job):
        self.ns['_run_archived_finalization'](
            np.array([0.1, -0.2], dtype=np.float32), {'microphone': 'Test'}, job, self.watchdog,
        )

    def test_audio_exists_before_decode_and_final_text_links_to_same_capture(self):
        def job():
            self.assertEqual(1, len(list(self.root.glob('*.wav'))))
            self.ns['_update_recording'](raw_transcript='yes please', text='Yes please.', status='completed')
        self.finish(job)
        entry = json.loads(next(self.root.glob('*.json')).read_text())
        self.assertEqual('yes please', entry['raw_transcript'])
        self.assertEqual('Yes please.', entry['text'])
        self.assertIsNone(self.ns['_recording_context'].recording_id)
        self.watchdog.complete.assert_called_once()

    def test_disk_failure_does_not_prevent_transcription_or_leave_finalizer_active(self):
        job = mock.Mock()
        with mock.patch.object(self.archive, 'save', side_effect=OSError('disk full')):
            self.finish(job)
        job.assert_called_once()
        self.log.assert_called_once()
        self.ns['_complete_finalization'].assert_called_once()
        self.watchdog.complete.assert_called_once()

    def test_transcription_failure_keeps_audio_and_error(self):
        with self.assertRaisesRegex(RuntimeError, 'decode failed'):
            self.finish(mock.Mock(side_effect=RuntimeError('decode failed')))
        entry = json.loads(next(self.root.glob('*.json')).read_text())
        self.assertEqual('finalization_error', entry['status'])
        self.assertEqual('decode failed', entry['error'])
        self.assertTrue((self.root / entry['audio_file']).exists())
        self.watchdog.complete.assert_called_once()

    def test_skipped_capture_is_retained_with_reason(self):
        self.finish(lambda: self.ns['_update_recording'](status='skipped_low_level'))
        entry = json.loads(next(self.root.glob('*.json')).read_text())
        self.assertEqual('skipped_low_level', entry['status'])

    def test_recording_can_be_disabled_without_affecting_dictation(self):
        self.ns['_settings']['audio_recording_enabled'] = False
        job = mock.Mock()
        self.finish(job)
        job.assert_called_once()
        self.assertFalse(self.root.exists())
