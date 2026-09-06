"""Run the real installer against disposable homes, never the user's config."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / "install-hooks.py"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="drem-installer-")
        self.addCleanup(self.temporary.cleanup)
        self.install_home = Path(self.temporary.name)
        self.binary = self.install_home / "Applications/drem.app/Contents/MacOS/drem-hook"
        self.binary.parent.mkdir(parents=True)
        self.binary.touch()
        self.codex = self.install_home / ".codex/hooks.json"
        self.claude = self.install_home / ".claude/settings.json"

    def run_installer(self):
        return subprocess.run(
            [sys.executable, str(INSTALLER)],
            env={**os.environ, "DREM_INSTALL_HOME": str(self.install_home), "DREM_HOOK_BINARY": str(self.binary)},
            capture_output=True, text=True, check=False,
        )

    def write_config(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    def test_new_install_uses_drem_and_private_permissions(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        for path, count in [(self.codex, 5), (self.claude, 5)]:
            data = json.loads(path.read_text())
            self.assertEqual(len(data["hooks"]), count)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            for groups in data["hooks"].values():
                self.assertIn(str(self.binary), groups[0]["hooks"][0]["command"])

    def test_upgrade_preserves_other_hooks_and_backs_up_exact_original(self):
        original = {
            "theme": "dark",
            "hooks": {"Stop": [{"hooks": [
                {"type": "command", "command": "/safe/example/other-hook"},
                {"type": "command", "command": '"/example/Agent Watch.app/Contents/MacOS/agentwatch-hook" codex'},
            ]}]},
        }
        self.write_config(self.codex, original)
        previous = self.codex.read_bytes()
        self.codex.chmod(0o640)
        self.assertEqual(self.run_installer().returncode, 0)
        updated = json.loads(self.codex.read_text())
        self.assertEqual(updated["theme"], "dark")
        entries = [item for group in updated["hooks"]["Stop"] for item in group["hooks"]]
        commands = [item["command"] for item in entries]
        self.assertIn("/safe/example/other-hook", commands)
        self.assertFalse(any("Agent Watch.app" in command for command in commands))
        self.assertEqual(len(entries), 2)
        backups = list(self.codex.parent.glob("hooks.json.drem-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), previous)
        self.assertEqual(self.codex.stat().st_mode & 0o777, 0o640)

    def test_repeated_install_has_no_duplicate_handlers(self):
        self.assertEqual(self.run_installer().returncode, 0)
        first = json.loads(self.codex.read_text())
        self.assertEqual(self.run_installer().returncode, 0)
        self.assertEqual(json.loads(self.codex.read_text()), first)

    def test_invalid_config_is_not_overwritten(self):
        self.codex.parent.mkdir(parents=True)
        self.codex.write_text("{invalid json", encoding="utf-8")
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.codex.read_text(), "{invalid json")
        self.assertFalse(self.claude.exists())

    def test_missing_binary_does_not_create_configs(self):
        self.binary.unlink()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertFalse(self.codex.exists())
        self.assertFalse(self.claude.exists())


if __name__ == "__main__":
    unittest.main()
