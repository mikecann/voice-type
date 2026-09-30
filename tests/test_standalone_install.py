import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class StandaloneInstallTests(unittest.TestCase):
    def test_mac_install_runs_setup_and_links_launcher_with_spaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = pathlib.Path(tmp)
            repo = base / "repo with spaces"
            repo.mkdir()
            shutil.copy2(ROOT / "install.sh", repo / "install.sh")
            setup_marker = repo / "setup-ran"
            (repo / "setup_mac.sh").write_text(
                '#!/usr/bin/env bash\ntouch "$(dirname "$0")/setup-ran"\n'
            )
            launcher = repo / "voice-type-mac.sh"
            launcher.write_text("#!/usr/bin/env bash\nexit 0\n")
            launcher.chmod(0o755)
            target = base / "bin with spaces"
            for _ in range(2):
                subprocess.run(["bash", str(repo / "install.sh"), str(target)], check=True)
                self.assertTrue(setup_marker.exists())
                self.assertEqual(launcher.resolve(), (target / "voice-type").resolve())
                setup_marker.unlink()
            (target / "voice-type").unlink()
            (target / "voice-type").write_text("my existing command")
            result = subprocess.run(
                ["bash", str(repo / "install.sh"), str(target)], capture_output=True
            )
            self.assertNotEqual(0, result.returncode)
            self.assertFalse(setup_marker.exists())
            self.assertEqual("my existing command", (target / "voice-type").read_text())

    def test_mac_runtime_stages_example_without_overwriting_user_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            runtime = pathlib.Path(tmp) / "runtime with spaces"
            env = os.environ.copy()
            env["VOICE_TYPE_INSTALL_DIR"] = str(runtime)
            for iteration in range(2):
                subprocess.run(["bash", str(ROOT / "install-runtime-mac.sh")], env=env, check=True)
                self.assertTrue((runtime / "voice-type.py").is_file())
                self.assertTrue(os.access(runtime / "launch-voice-type-mac.sh", os.X_OK))
                if iteration == 0:
                    self.assertEqual(
                        (ROOT / "settings.example.json").read_text(),
                        (runtime / "settings.json").read_text(),
                    )
                    (runtime / "settings.json").write_text('{"microphone_name": "My mic"}')
                else:
                    self.assertEqual('{"microphone_name": "My mic"}', (runtime / "settings.json").read_text())
            # setup_mac.sh may stage an already installed runtime in place.
            subprocess.run(["bash", str(runtime / "install-runtime-mac.sh")], env=env, check=True)
            self.assertEqual('{"microphone_name": "My mic"}', (runtime / "settings.json").read_text())


if __name__ == "__main__":
    unittest.main()
