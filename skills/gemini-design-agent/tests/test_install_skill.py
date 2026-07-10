import json
import hashlib
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import patch

import sys

SKILL_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SKILL_DIR.parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from install_skill import GitState, InstallerError, SkillInstaller, SwiftTarget, verify_manifest


def write_fake_binary(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "args = sys.argv[1:]\n"
        "if os.environ.get('GDA_FAKE_RECORD_PATH'):\n"
        "    with open(os.environ['GDA_FAKE_RECORD_PATH'], 'a', encoding='utf-8') as record:\n"
        "        record.write(json.dumps(args) + '\\n')\n"
        "if args == ['version', '--json']:\n"
        "    print(json.dumps({'version': '0.1.0', 'skill_protocol_version': '1'}))\n"
        "elif args == ['--version']:\n"
        "    print('0.1.0')\n"
        "elif args == ['auth', 'status', '--json']:\n"
        "    print(json.dumps({'ok': True, 'data': {'configured': False}}))\n"
        "else:\n"
        "    print('help')\n",
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class InstallerHarness:
    def __init__(self, root: Path, *, allow_dirty=False, replace_unmanaged=False, dry_run=False):
        self.source = root / "source checkout with spaces"
        self.codex_home = root / "codex home with spaces"
        self.source.mkdir(parents=True)
        (self.source / "Package.swift").write_text("// test\n", encoding="utf-8")
        shutil.copytree(SKILL_DIR, self.source / "skills" / "gemini-design-agent")
        self.binary = root / "build output with spaces" / "gda"
        write_fake_binary(self.binary)
        self.installer = SkillInstaller(
            source_root=self.source,
            codex_home=self.codex_home,
            allow_dirty=allow_dirty,
            replace_unmanaged=replace_unmanaged,
            dry_run=dry_run,
        )

    def patches(self, *, dirty=False):
        smoke_patch = (
            patch.object(self.installer, "_smoke_bundle", side_effect=verify_manifest)
            if os.name == "nt"
            else nullcontext()
        )
        return (
            patch.object(self.installer, "_swift_version", return_value=(6, 1, 0)),
            patch.object(
                self.installer,
                "_git_state",
                return_value=GitState(commit="a" * 40, dirty=dirty),
            ),
            patch.object(
                self.installer,
                "_swift_target",
                return_value=SwiftTarget(
                    platform="macos",
                    architecture="arm64",
                    triple="arm64-apple-macosx",
                ),
            ),
            patch.object(self.installer, "_build_release", return_value=self.binary),
            smoke_patch,
        )


class InstallSkillTests(unittest.TestCase):
    def test_fresh_install_and_idempotent_reinstall_in_paths_with_spaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                first = harness.installer.install()
                second = harness.installer.install()

            self.assertTrue(first["installed"])
            self.assertTrue(second["installed"])
            self.assertEqual(second["existing_state"], "managed")
            manifest = verify_manifest(harness.installer.target)
            self.assertEqual(manifest["product_version"], "0.1.0")
            self.assertEqual(manifest["skill_protocol_version"], "1")
            self.assertFalse(harness.installer.lock.exists())
            self.assertFalse((harness.installer.target / "__pycache__").exists())

    @unittest.skipIf(os.name == "nt", "POSIX fake binary; Windows CI exercises the native installed gda.exe")
    def test_managed_wrapper_runs_twice_without_writing_bytecode(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                harness.installer.install()

            env = os.environ.copy()
            env.pop("PYTHONDONTWRITEBYTECODE", None)
            env["GDA_BIN"] = ""
            for invocation in range(2):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(harness.installer.target / "gda_skill.py"),
                        "capabilities",
                    ],
                    cwd=harness.installer.target,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=30,
                    shell=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                self.assertTrue(payload["ok"])
                self.assertEqual(payload["data"]["install_manifest_health"], "valid")
                self.assertFalse(
                    (harness.installer.target / "__pycache__").exists(),
                    f"invocation {invocation + 1} wrote a cache directory",
                )
                self.assertEqual(list(harness.installer.target.rglob("*.pyc")), [])

    @unittest.skipIf(os.name == "nt", "POSIX fake binary; Windows CI exercises the native installed gda.exe")
    def test_installer_smoke_checks_auth_help_without_querying_credential_store(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            record_path = Path(tmp) / "fake-gda-commands.jsonl"
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with patch.dict(os.environ, {"GDA_FAKE_RECORD_PATH": str(record_path)}, clear=False):
                with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                    harness.installer.install()

            commands = [json.loads(line) for line in record_path.read_text(encoding="utf-8").splitlines()]
            self.assertIn(["help", "auth"], commands)
            self.assertIn(["help", "auth", "status"], commands)
            self.assertNotIn(["auth", "status", "--json"], commands)

    def test_dry_run_does_not_build_or_create_codex_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp), dry_run=True)
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch as build, smoke_patch:
                result = harness.installer.install()

            self.assertTrue(result["dry_run"])
            build.assert_not_called()
            self.assertFalse(harness.codex_home.exists())

    def test_dirty_source_requires_allow_dirty(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp), dry_run=True)
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches(dirty=True)
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                with self.assertRaises(InstallerError) as raised:
                    harness.installer.install()

            self.assertEqual(raised.exception.code, "SOURCE_DIRTY")

    def test_unmanaged_install_refuses_without_explicit_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            harness.installer.target.mkdir(parents=True)
            (harness.installer.target / "personal.txt").write_text("keep", encoding="utf-8")
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                with self.assertRaises(InstallerError) as raised:
                    harness.installer.install()

            self.assertEqual(raised.exception.code, "INSTALL_REPLACEMENT_REQUIRED")
            self.assertEqual(
                (harness.installer.target / "personal.txt").read_text(encoding="utf-8"),
                "keep",
            )

    def test_source_with_unexpected_runtime_module_is_rejected_before_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            (harness.installer.skill_source / "gda_extra.py").write_text(
                "DEBUG_ONLY = True\n",
                encoding="utf-8",
            )
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch as build, smoke_patch:
                with self.assertRaises(InstallerError) as raised:
                    harness.installer.install()

            self.assertEqual(raised.exception.code, "SKILL_VALIDATION_FAILED")
            self.assertIn("SKILL_RUNTIME_FILE_UNEXPECTED", str(raised.exception))
            build.assert_not_called()

    def test_replace_unmanaged_is_explicit_and_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp), replace_unmanaged=True)
            harness.installer.target.mkdir(parents=True)
            (harness.installer.target / "old.txt").write_text("old", encoding="utf-8")
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                result = harness.installer.install()

            self.assertTrue(result["installed"])
            self.assertFalse((harness.installer.target / "old.txt").exists())
            verify_manifest(harness.installer.target)

    def test_modified_managed_install_requires_explicit_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                harness.installer.install()
            (harness.installer.target / "gda_constants.py").write_text("modified\n", encoding="utf-8")

            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                with self.assertRaises(InstallerError) as raised:
                    harness.installer.install()

            self.assertEqual(raised.exception.code, "INSTALL_REPLACEMENT_REQUIRED")

    def test_installer_manifest_rejects_unrelated_extra_file_and_nested_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                harness.installer.install()

            personal = harness.installer.target / "personal.txt"
            personal.write_text("do not delete", encoding="utf-8")
            with self.assertRaises(InstallerError) as extra_file:
                verify_manifest(harness.installer.target)
            self.assertEqual(extra_file.exception.code, "INSTALL_MODIFIED")
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch as build, smoke_patch:
                with self.assertRaises(InstallerError) as reinstall:
                    harness.installer.install()
            self.assertEqual(reinstall.exception.code, "INSTALL_REPLACEMENT_REQUIRED")
            build.assert_not_called()
            personal.unlink()

            cache = harness.installer.target / "__pycache__"
            cache.mkdir()
            (cache / "gda_runner.pyc").write_bytes(b"cache")
            with self.assertRaises(InstallerError) as nested_cache:
                verify_manifest(harness.installer.target)
            self.assertEqual(nested_cache.exception.code, "INSTALL_MODIFIED")
            self.assertIn("__pycache__", str(nested_cache.exception))

    def test_post_install_smoke_failure_rolls_back_previous_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                harness.installer.install()
            previous_manifest = (harness.installer.target / ".gda-install-manifest.json").read_bytes()

            source_constants = harness.installer.skill_source / "gda_constants.py"
            source_constants.write_text(
                source_constants.read_text(encoding="utf-8") + "\nROLLBACK_TEST = True\n",
                encoding="utf-8",
            )
            original_smoke = harness.installer._smoke_bundle

            def fail_only_after_replace(path: Path):
                if path == harness.installer.target:
                    raise InstallerError("SMOKE_FAILED", "forced post-install failure")
                return original_smoke(path)

            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                with patch.object(harness.installer, "_smoke_bundle", side_effect=fail_only_after_replace):
                    with self.assertRaises(InstallerError):
                        harness.installer.install()

            self.assertEqual(
                (harness.installer.target / ".gda-install-manifest.json").read_bytes(),
                previous_manifest,
            )
            verify_manifest(harness.installer.target)

    def test_manifest_rejects_unexpected_and_modified_runtime_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                harness.installer.install()

            manifest_path = harness.installer.target / ".gda-install-manifest.json"
            extra = harness.installer.target / "gda_extra.py"
            extra.write_text("EXTRA = True\n", encoding="utf-8")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["files"]["gda_extra.py"] = hashlib.sha256(extra.read_bytes()).hexdigest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaises(InstallerError) as raised:
                verify_manifest(harness.installer.target)
            self.assertEqual(raised.exception.code, "INSTALL_MODIFIED")

    @unittest.skipIf(os.name == "nt", "Unix symlink semantics")
    def test_manifest_rejects_runtime_symlink_even_when_contents_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                harness.installer.install()

            runtime_file = harness.installer.target / "gda_constants.py"
            external_copy = Path(tmp) / "external-constants.py"
            shutil.copy2(runtime_file, external_copy)
            runtime_file.unlink()
            runtime_file.symlink_to(external_copy)

            with self.assertRaises(InstallerError) as raised:
                verify_manifest(harness.installer.target)
            self.assertEqual(raised.exception.code, "INSTALL_MODIFIED")

    def test_target_change_during_build_is_rejected_before_replacement(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            harness.installer.target.mkdir(parents=True)

            with self.assertRaises(InstallerError) as raised:
                harness.installer._verify_target_unchanged("absent")

            self.assertEqual(raised.exception.code, "INSTALL_TARGET_CHANGED")

    def test_existing_install_lock_blocks_preflight(self):
        with tempfile.TemporaryDirectory() as tmp:
            harness = InstallerHarness(Path(tmp))
            harness.installer.lock.mkdir(parents=True)
            swift_patch, git_patch, target_patch, build_patch, smoke_patch = harness.patches()
            with swift_patch, git_patch, target_patch, build_patch, smoke_patch:
                with self.assertRaises(InstallerError) as raised:
                    harness.installer.install()

            self.assertEqual(raised.exception.code, "INSTALL_LOCKED")


if __name__ == "__main__":
    unittest.main()
