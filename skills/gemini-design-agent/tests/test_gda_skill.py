import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys

SKILL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL_DIR))

from gda_envelope import GDASkillError
from gda_handoff import normalize_handoff, validate_normalized_handoff
from gda_runner import find_gda, run_gda
from gda_commands import ensure_auth, lock_clear


class GDASkillWrapperTests(unittest.TestCase):
    def test_find_gda_prefers_env_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "gda"
            binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            binary.chmod(binary.stat().st_mode | stat.S_IXUSR)

            with patch.dict(os.environ, {"GDA_BIN": str(binary)}, clear=False):
                self.assertEqual(find_gda(), str(binary))

    def test_run_gda_preserves_structured_error_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "gda"
            payload = {
                "ok": False,
                "command": "doctor",
                "schema_version": "1.0",
                "error": {"code": "TEST_ERROR", "message": "preserved"},
            }
            binary.write_text(
                "#!/bin/sh\nprintf '%s\\n' '" + json.dumps(payload) + "'\nexit 7\n",
                encoding="utf-8",
            )
            binary.chmod(binary.stat().st_mode | stat.S_IXUSR)

            with patch.dict(os.environ, {"GDA_BIN": str(binary)}, clear=False):
                with self.assertRaises(GDASkillError) as raised:
                    run_gda(["doctor"], timeout_seconds=5)

            self.assertEqual(raised.exception.payload["error"]["code"], "TEST_ERROR")

    def test_handoff_validation_accepts_existing_png_path_and_screen(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "screen.png"
            image.write_bytes(b"not-a-real-png-for-wrapper-validation")
            normalized = normalize_handoff({
                "source": {"platform": "figma_mcp"},
                "asset": {"image_path": str(image)},
                "analysis": {"screen": "Home"},
            })

            valid, issues = validate_normalized_handoff(normalized)

            self.assertTrue(valid)
            self.assertEqual([i for i in issues if i["severity"] == "error"], [])

    def test_ensure_auth_headless_returns_unavailable_payload(self):
        with patch.dict(os.environ, {"GDA_DISABLE_AUTH_ONBOARDING": "1"}, clear=False):
            with patch("gda_commands.auth_status", return_value={"data": {"configured": False}}):
                with self.assertRaises(GDASkillError) as raised:
                    ensure_auth(auto_open_terminal=True)

        self.assertEqual(raised.exception.payload["error"]["code"], "AUTH_ONBOARDING_UNAVAILABLE")

    def test_lock_clear_requires_explicit_force(self):
        with self.assertRaises(GDASkillError):
            lock_clear(project_dir=".gda", force=False)


if __name__ == "__main__":
    unittest.main()
