import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SCRIPT = REPO_ROOT / "scripts" / "install.sh"


@unittest.skipIf(os.name == "nt", "The Bash bootstrap supports macOS and Linux.")
class InstallBootstrapTests(unittest.TestCase):
    def run_script(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        return subprocess.run(
            [bash, str(INSTALL_SCRIPT), *arguments],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            shell=False,
        )

    def test_help_documents_current_and_tagged_clone_workflows(self):
        result = self.run_script("--help")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "git clone --depth 1 https://github.com/AmrMohamad/GeminiDesignAgent.git",
            result.stdout,
        )
        self.assertIn("git clone --depth 1 --branch v0.1.0", result.stdout)
        self.assertIn("./scripts/install.sh --version v0.1.0", result.stdout)

    def test_version_mismatch_is_rejected_before_installer_execution(self):
        result = self.run_script(
            "--dry-run",
            "--allow-dirty",
            "--version", "v9.9.9",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "requested version v9.9.9 does not match checkout version v0.1.0",
            result.stderr,
        )

    def test_dry_run_delegates_to_deterministic_installer_without_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            codex_home = Path(temporary) / "Codex Home"
            result = self.run_script(
                "--dry-run",
                "--allow-dirty",
                "--version", "v0.1.0",
                "--codex-home", str(codex_home),
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"dry_run": true', result.stdout)
            self.assertIn("Dry run complete; no build or installation was performed.", result.stdout)
            self.assertFalse(codex_home.exists())


if __name__ == "__main__":
    unittest.main()
