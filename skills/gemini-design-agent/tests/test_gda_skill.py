import json
import hashlib
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys

SKILL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL_DIR))

from gda_envelope import GDASkillError
from gda_handoff import normalize_handoff, validate_normalized_handoff
import gda_runner
from gda_constants import RUNTIME_PYTHON_FILES
from gda_cli import build_parser, dispatch
from gda_runner import find_gda, resolve_gda, run_gda, verify_install_manifest
from gda_commands import analyze, capabilities, ensure_auth, lock_clear, runs_stats


def write_fake_gda(path: Path, *, version: str = "0.1.0", protocol: str = "1", failure=None):
    failure = failure or {
        "ok": False,
        "command": "doctor",
        "schema_version": "1.0",
        "error": {"code": "TEST_ERROR", "message": "preserved"},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"version": version, "protocol": protocol, "failure": failure}),
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def write_managed_bundle(path: Path) -> None:
    (path / "bin").mkdir(parents=True)
    runtime_files = ["SKILL.md", *RUNTIME_PYTHON_FILES, f"bin/{gda_runner._binary_name()}"]
    hashes = {}
    for relative in runtime_files:
        runtime_path = path / relative
        runtime_path.write_text(relative, encoding="utf-8")
        hashes[relative] = hashlib.sha256(runtime_path.read_bytes()).hexdigest()
    (path / ".gda-install-manifest.json").write_text(
        json.dumps({"schema_version": "1", "files": hashes}),
        encoding="utf-8",
    )


class GDASkillWrapperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.subprocess_run = patch(
            "gda_runner.subprocess.run",
            side_effect=self.run_fake_gda,
        )
        self.subprocess_run.start()
        self.addCleanup(self.subprocess_run.stop)

    @staticmethod
    def run_fake_gda(command, **_kwargs):
        fixture = json.loads(Path(command[0]).read_text(encoding="utf-8"))
        if command[1:] == ["version", "--json"]:
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=json.dumps({
                    "version": fixture["version"],
                    "skill_protocol_version": fixture["protocol"],
                }),
                stderr="",
            )
        return subprocess.CompletedProcess(
            command,
            7,
            stdout=json.dumps(fixture["failure"]),
            stderr="",
        )

    def test_find_gda_prefers_env_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / gda_runner._binary_name()
            write_fake_gda(binary)

            with patch.dict(os.environ, {"GDA_BIN": str(binary)}, clear=False):
                self.assertEqual(find_gda(), str(binary.resolve()))

    def test_capabilities_match_current_prompt_and_database_contracts(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / gda_runner._binary_name()
            write_fake_gda(binary)
            with patch.dict(os.environ, {"GDA_BIN": str(binary)}, clear=False):
                payload = capabilities()
        self.assertEqual(payload["data"]["prompt_schema_version"], "1.2")
        self.assertEqual(payload["data"]["database_schema_version"], 3)

    def test_find_gda_rejects_protocol_mismatch_with_structured_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / gda_runner._binary_name()
            write_fake_gda(binary, protocol="2")

            with patch.dict(os.environ, {"GDA_BIN": str(binary)}, clear=False):
                with self.assertRaises(GDASkillError) as raised:
                    resolve_gda()

            self.assertEqual(raised.exception.payload["error"]["code"], "GDA_PROTOCOL_MISMATCH")
            diagnostic = raised.exception.payload["diagnostics"][0]
            self.assertEqual(diagnostic["required_protocol_version"], "1")
            self.assertEqual(diagnostic["binary_protocol_version"], "2")

    def test_external_compatible_binary_allows_product_version_difference_with_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / gda_runner._binary_name()
            write_fake_gda(binary, version="0.1.1", protocol="1")

            with patch.dict(os.environ, {"GDA_BIN": str(binary)}, clear=False):
                resolution = resolve_gda()

            self.assertEqual(resolution.source, "environment")
            self.assertEqual(resolution.binary_version, "0.1.1")
            self.assertEqual(len(resolution.warnings), 1)

    def test_resolution_prefers_bundled_then_checkout_then_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "repo"
            skill = root / "skills" / "gemini-design-agent"
            fake_module = skill / "gda_runner.py"
            fake_module.parent.mkdir(parents=True)
            fake_module.touch()
            binary_name = gda_runner._binary_name()
            bundled = skill / "bin" / binary_name
            checkout = root / ".build" / "release" / binary_name
            path_binary = Path(tmp) / "path" / binary_name
            write_fake_gda(bundled)
            write_fake_gda(checkout)
            write_fake_gda(path_binary)

            with patch.object(gda_runner, "__file__", str(fake_module)):
                with patch.dict(os.environ, {"GDA_BIN": ""}, clear=False):
                    with patch("gda_runner.shutil.which", return_value=str(path_binary)):
                        self.assertEqual(resolve_gda().source, "bundled")
                        bundled.unlink()
                        self.assertEqual(resolve_gda().source, "checkout_release")
                        checkout.unlink()
                        self.assertEqual(resolve_gda().source, "path")

    def test_managed_manifest_cannot_legitimize_extra_runtime_module(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "gemini-design-agent"
            write_managed_bundle(skill)
            extra = skill / "gda_extra.py"
            extra.write_text("extra", encoding="utf-8")
            manifest_path = skill / ".gda-install-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["files"]["gda_extra.py"] = hashlib.sha256(extra.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaises(GDASkillError):
                verify_install_manifest(skill)

    def test_wrapper_manifest_rejects_unrelated_extra_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "gemini-design-agent"
            write_managed_bundle(skill)
            (skill / "personal.txt").write_text("do not delete", encoding="utf-8")

            with self.assertRaises(GDASkillError) as raised:
                verify_install_manifest(skill)

            self.assertIn("unexpected=['personal.txt']", str(raised.exception))

    def test_wrapper_manifest_rejects_nested_cache_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "gemini-design-agent"
            write_managed_bundle(skill)
            cache = skill / "__pycache__"
            cache.mkdir()
            (cache / "gda_runner.pyc").write_bytes(b"cache")

            with self.assertRaises(GDASkillError) as raised:
                verify_install_manifest(skill)

            self.assertIn("__pycache__", str(raised.exception))

    def test_run_gda_preserves_structured_error_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / gda_runner._binary_name()
            payload = {
                "ok": False,
                "command": "doctor",
                "schema_version": "1.0",
                "error": {"code": "TEST_ERROR", "message": "preserved"},
            }
            write_fake_gda(binary, failure=payload)

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

    def test_runs_stats_forwards_arguments_and_preserves_envelope(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp) / "project with spaces.gda"
            envelope = {
                "ok": True,
                "command": "runs.stats",
                "schema_version": "1.0",
                "data": {"total_runs": 2},
                "diagnostics": [],
                "next_actions": [],
            }
            with patch("gda_commands.run_gda", return_value=envelope) as runner:
                result = runs_stats(project_dir=str(project), since_days=14)

            self.assertIs(result, envelope)
            runner.assert_called_once_with(
                [
                    "runs",
                    "stats",
                    "--project-dir", str(project.resolve()),
                    "--since-days", "14",
                ],
                timeout_seconds=60,
            )

    def test_analyze_forwards_timeout_to_installed_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "screen.png"
            image.write_bytes(b"synthetic smoke image")

            with patch("gda_commands.ensure_auth"):
                with patch("gda_commands.run_gda", return_value={"ok": True}) as runner:
                    result = analyze(
                        image=str(image),
                        screen="Login",
                        request="Extract reusable design values.",
                        project_dir=str(Path(tmp) / "project.gda"),
                        timeout_seconds=300,
                    )

            self.assertEqual(result, {"ok": True})
            runner.assert_called_once_with(
                [
                    "analyze",
                    "--project-dir", str((Path(tmp) / "project.gda").resolve()),
                    "--image", str(image.resolve()),
                    "--screen", "Login",
                    "--request", "Extract reusable design values.",
                    "--timeout-seconds", "300",
                ],
                timeout_seconds=300,
            )

    def test_runs_stats_parser_dispatches_public_wrapper_command(self):
        args = build_parser().parse_args([
            "runs-stats",
            "--project-dir", "metrics.gda",
            "--since-days", "7",
        ])
        expected = {"ok": True, "command": "runs.stats", "data": {}}

        with patch("gda_cli.runs_stats", return_value=expected) as command:
            result = dispatch(args)

        self.assertIs(result, expected)
        command.assert_called_once_with(project_dir="metrics.gda", since_days=7)


if __name__ == "__main__":
    unittest.main()
