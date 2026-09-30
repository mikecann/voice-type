import os
import pathlib
import plistlib
import subprocess
import shutil
import sys
import tempfile
import unittest


VOICE_TYPE_DIR = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = VOICE_TYPE_DIR / "install-spotlight-app.sh"


class SpotlightAppInstallerTests(unittest.TestCase):
    def test_setup_supports_the_uv_managed_python_used_on_this_mac(self):
        setup = (VOICE_TYPE_DIR / "setup_mac.sh").read_text()
        self.assertIn("uv python find 3.12", setup)

    def test_setup_preserves_the_native_launchers_tcc_identity(self):
        setup = (VOICE_TYPE_DIR / "setup_mac.sh").read_text()
        self.assertIn("Preserving existing native launcher identity", setup)
        self.assertIn("VOICE_TYPE_TRUSTED_LAUNCHER", setup)
        self.assertIn("trusted-launcher-path", setup)
        self.assertIn("VOICE_TYPE_REBUILD_LAUNCHER", setup)
        self.assertIn('designated => identifier "com.mikerosoft.voice-type"', setup)

    def test_settings_launcher_recovers_from_a_stale_control_socket(self):
        launcher = (VOICE_TYPE_DIR / "open-settings-mac.sh").read_text()
        self.assertIn("restart_after_failed_request", launcher)
        self.assertIn('rm -f "$SOCKET_PATH"', launcher)

    @unittest.skipUnless(
        sys.platform == "darwin" and os.environ.get("VOICE_TYPE_TEST_NATIVE_APP") == "1",
        "Native Spotlight registration is opt-in on macOS",
    )
    def test_installs_application_bundle_that_opens_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = pathlib.Path(tmp) / "Voice Type.app"
            env = os.environ.copy()
            env["VOICE_TYPE_APP_DIR"] = str(app_dir)

            subprocess.run(["bash", str(INSTALLER)], env=env, check=True)

            executable = app_dir / "Contents" / "MacOS" / "voice-type-settings"
            plist_path = app_dir / "Contents" / "Info.plist"
            self.assertTrue(os.access(executable, os.X_OK))
            self.assertIn(str(VOICE_TYPE_DIR / "open-settings-mac.sh"), executable.read_text())

            with plist_path.open("rb") as stream:
                plist = plistlib.load(stream)
            self.assertEqual("com.mikerosoft.voice-type", plist["CFBundleIdentifier"])
            self.assertEqual("Voice Type", plist["CFBundleDisplayName"])
            self.assertEqual("voice-type-settings", plist["CFBundleExecutable"])

    def test_bundle_contents_without_native_desktop_integration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            source = root / "source with spaces"
            source.mkdir()
            shutil.copy2(INSTALLER, source / INSTALLER.name)
            # No icon source: this test verifies the launcher and plist, while
            # the opt-in native test covers icon conversion and signing.
            commands = root / "bin"
            commands.mkdir()
            for name in ("codesign", "mdimport", "lsregister"):
                command = commands / name
                command.write_text("#!/usr/bin/env bash\nexit 0\n")
                command.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{commands}:{env['PATH']}"
            env["VOICE_TYPE_APP_DIR"] = str(root / "Voice Type.app")
            env["VOICE_TYPE_LSREGISTER"] = str(commands / "lsregister")
            subprocess.run(["bash", str(source / INSTALLER.name)], env=env, check=True)
            app = pathlib.Path(env["VOICE_TYPE_APP_DIR"])
            launcher = app / "Contents/MacOS/voice-type-settings"
            self.assertTrue(os.access(launcher, os.X_OK))
            self.assertIn(str(source / "open-settings-mac.sh"), launcher.read_text())
            with (app / "Contents/Info.plist").open("rb") as stream:
                plist = plistlib.load(stream)
            self.assertEqual("com.mikerosoft.voice-type", plist["CFBundleIdentifier"])
            self.assertEqual("voice-type-settings", plist["CFBundleExecutable"])


if __name__ == "__main__":
    unittest.main()
