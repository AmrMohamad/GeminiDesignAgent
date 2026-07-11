import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="gda-package-release-"))
        (self.root / "scripts").mkdir()
        contract = self.root / "Sources/GeminiDesignAgentCore/Utilities"
        contract.mkdir(parents=True)
        shutil.copy2(pathlib.Path(__file__).parents[1] / "scripts/package_release.py", self.root / "scripts/package_release.py")
        (contract / "GDAContract.swift").write_text('enum GDAContract { static let productVersion = "0.1.0" }\n')
        (self.root / "README.md").write_text("release fixture\n")
        self.command("git", "init", "-b", "main")
        self.command("git", "config", "user.email", "test@example.com")
        self.command("git", "config", "user.name", "Test")
        self.command("git", "add", ".")
        self.command("git", "commit", "-m", "fixture")

    def tearDown(self):
        def remove_readonly(function, path, _exception):
            os.chmod(path, os.stat(path).st_mode | stat.S_IWRITE)
            function(path)

        shutil.rmtree(self.root, onexc=remove_readonly)

    def command(self, *args):
        return subprocess.run(args, cwd=self.root, text=True, check=True, capture_output=True)

    def test_creates_prefixed_archive_and_checksum(self):
        result = self.command("python3", "scripts/package_release.py", "--version", "0.1.0", "--output", "dist", "--skip-gates")
        self.assertIn('"ok": true', result.stdout)
        self.assertTrue((self.root / "dist/GeminiDesignAgent-0.1.0.zip").exists())
        self.assertIn("GeminiDesignAgent-0.1.0.zip", (self.root / "dist/SHA256SUMS").read_text())

    def test_rejects_dirty_worktree(self):
        (self.root / "dirty.txt").write_text("nope\n")
        result = subprocess.run(["python3", "scripts/package_release.py", "--version", "0.1.0", "--skip-gates"], cwd=self.root, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean worktree", result.stderr)
