#!/usr/bin/env python3
"""Build and atomically install the Gemini Design Agent Codex skill."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from validate_skill import EXPECTED_SKILL_NAME, runtime_files, validate_skill_dir


PRODUCT_VERSION = "0.1.0"
SKILL_PROTOCOL_VERSION = "1"
MANIFEST_NAME = ".gda-install-manifest.json"
MINIMUM_SWIFT_VERSION = (6, 1, 0)


class InstallerError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class GitState:
    commit: str
    dirty: bool


@dataclass(frozen=True)
class SwiftTarget:
    platform: str
    architecture: str
    triple: str


def _run(
    command: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 600,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            shell=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise InstallerError("COMMAND_FAILED", f"Could not execute {command[0]}: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise InstallerError("COMMAND_FAILED", f"Command failed ({' '.join(command)}): {detail}")
    return result


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _binary_name() -> str:
    return "gda.exe" if os.name == "nt" else "gda"


def _expected_bundle_files(skill_dir: Path) -> set[str]:
    files = {"SKILL.md", f"bin/{_binary_name()}"}
    files.update(path.name for path in runtime_files(skill_dir))
    return files


def _bundle_shape(root: Path) -> dict[str, str]:
    shape: dict[str, str] = {}
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError as exc:
            raise InstallerError("INSTALL_MODIFIED", f"Could not enumerate installed skill bundle: {exc}") from exc
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            if entry.is_symlink():
                shape[relative] = "symlink"
            elif entry.is_dir(follow_symlinks=False):
                shape[relative] = "directory"
                pending.append(path)
            elif entry.is_file(follow_symlinks=False):
                shape[relative] = "file"
            else:
                shape[relative] = "other"
    return shape


def _expected_bundle_shape(skill_dir: Path) -> dict[str, str]:
    files = {relative: "file" for relative in _expected_bundle_files(skill_dir)}
    return {
        MANIFEST_NAME: "file",
        "bin": "directory",
        **files,
    }


def verify_manifest(skill_dir: Path) -> dict[str, Any]:
    manifest_path = skill_dir / MANIFEST_NAME
    if manifest_path.exists() or manifest_path.is_symlink():
        actual_shape = _bundle_shape(skill_dir)
        expected_shape = _expected_bundle_shape(skill_dir)
        if actual_shape != expected_shape:
            unexpected = sorted(set(actual_shape) - set(expected_shape))
            missing = sorted(set(expected_shape) - set(actual_shape))
            mismatched = sorted(
                path for path in set(actual_shape) & set(expected_shape)
                if actual_shape[path] != expected_shape[path]
            )
            raise InstallerError(
                "INSTALL_MODIFIED",
                "Installed skill bundle shape is not exact "
                f"(unexpected={unexpected}, missing={missing}, type_mismatch={mismatched}).",
            )
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise InstallerError("INSTALL_UNMANAGED", "Existing skill has no managed-install manifest.") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise InstallerError("INSTALL_MANIFEST_INVALID", f"Could not read install manifest: {exc}") from exc

    files = manifest.get("files")
    if manifest.get("schema_version") != "1" or not isinstance(files, dict):
        raise InstallerError("INSTALL_MANIFEST_INVALID", "Install manifest schema is invalid.")
    if set(files) != _expected_bundle_files(skill_dir):
        raise InstallerError(
            "INSTALL_MANIFEST_INVALID",
            "Install manifest does not describe the exact runtime bundle.",
        )
    for relative, expected_hash in files.items():
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise InstallerError("INSTALL_MANIFEST_INVALID", "Install manifest contains an unsafe path.")
        path = skill_dir / relative_path
        if path.is_symlink() or not path.is_file() or _sha256(path) != expected_hash:
            raise InstallerError("INSTALL_MODIFIED", f"Installed runtime file was modified: {relative}")
    return manifest


def _decode_version_json(raw: str) -> dict[str, Any]:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise InstallerError("SMOKE_FAILED", "gda version --json returned invalid JSON.") from exc
    metadata = payload.get("data", payload) if isinstance(payload, dict) else {}
    if not isinstance(metadata, dict):
        raise InstallerError("SMOKE_FAILED", "gda version metadata has an invalid shape.")
    return metadata


class SkillInstaller:
    def __init__(
        self,
        *,
        source_root: Path,
        codex_home: Path,
        allow_dirty: bool = False,
        replace_unmanaged: bool = False,
        dry_run: bool = False,
        oauth_client_secrets: Path | None = None,
    ):
        self.source_root = source_root.expanduser().resolve()
        self.codex_home = codex_home.expanduser().resolve()
        self.skill_source = self.source_root / "skills" / EXPECTED_SKILL_NAME
        self.skills_dir = self.codex_home / "skills"
        self.target = self.skills_dir / EXPECTED_SKILL_NAME
        self.lock = self.skills_dir / f".{EXPECTED_SKILL_NAME}.install.lock"
        self.allow_dirty = allow_dirty
        self.replace_unmanaged = replace_unmanaged
        self.dry_run = dry_run
        self.oauth_client_secrets = oauth_client_secrets.expanduser().resolve() if oauth_client_secrets else None

    def _swift_version(self) -> tuple[int, int, int]:
        output = _run(["swift", "--version"], cwd=self.source_root, timeout=30).stdout
        match = re.search(r"Swift version\s+(\d+)\.(\d+)(?:\.(\d+))?", output, re.IGNORECASE)
        if not match:
            raise InstallerError("SWIFT_VERSION_UNKNOWN", "Could not parse swift --version output.")
        return tuple(int(part or 0) for part in match.groups())

    def _git_state(self) -> GitState:
        commit = _run(["git", "rev-parse", "HEAD"], cwd=self.source_root, timeout=30).stdout.strip()
        status = _run(
            ["git", "status", "--porcelain", "--untracked-files=normal"],
            cwd=self.source_root,
            timeout=30,
        ).stdout
        return GitState(commit=commit, dirty=bool(status.strip()))

    def _swift_target(self) -> SwiftTarget:
        raw = _run(["swift", "-print-target-info"], cwd=self.source_root, timeout=30).stdout
        try:
            target = json.loads(raw)["target"]
            triple = target.get("unversionedTriple") or target["triple"]
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            raise InstallerError("SWIFT_TARGET_UNKNOWN", "Could not parse swift -print-target-info output.") from exc
        architecture = str(triple).split("-", 1)[0].lower()
        lowered = str(triple).lower()
        if "windows" in lowered:
            platform_name = "windows"
        elif "linux" in lowered:
            platform_name = "linux"
        elif "apple" in lowered and ("macos" in lowered or "darwin" in lowered):
            platform_name = "macos"
        else:
            raise InstallerError("SWIFT_TARGET_UNSUPPORTED", f"Unsupported Swift target triple: {triple}")
        return SwiftTarget(platform=platform_name, architecture=architecture, triple=str(triple))

    def _existing_state(self) -> str:
        if not self.target.exists() and not self.target.is_symlink():
            return "absent"
        if self.target.is_symlink() or not self.target.is_dir():
            return "unsafe"
        try:
            verify_manifest(self.target)
            return "managed"
        except InstallerError as exc:
            if exc.code == "INSTALL_UNMANAGED":
                return "unmanaged"
            return "managed_modified"

    def preflight(self) -> tuple[GitState, tuple[int, int, int], SwiftTarget, str]:
        if not (self.source_root / "Package.swift").is_file():
            raise InstallerError("PACKAGE_MISSING", "Package.swift was not found at the source root.")
        if self.oauth_client_secrets is not None and not self.oauth_client_secrets.is_file():
            raise InstallerError("OAUTH_CLIENT_MISSING", "The supplied desktop OAuth client JSON was not found.")
        issues = validate_skill_dir(self.skill_source)
        if issues:
            summary = "; ".join(f"{issue.code}: {issue.message}" for issue in issues)
            raise InstallerError("SKILL_VALIDATION_FAILED", summary)

        swift_version = self._swift_version()
        if swift_version < MINIMUM_SWIFT_VERSION:
            raise InstallerError(
                "SWIFT_TOO_OLD",
                f"Swift 6.1 or newer is required; found {'.'.join(map(str, swift_version))}.",
            )
        swift_target = self._swift_target()
        git_state = self._git_state()
        if git_state.dirty and not self.allow_dirty:
            raise InstallerError(
                "SOURCE_DIRTY",
                "The source checkout has uncommitted changes; use --allow-dirty for a development install.",
            )
        if self.lock.exists():
            raise InstallerError("INSTALL_LOCKED", "Another skill installation appears to be running.")

        existing_state = self._existing_state()
        if existing_state == "unsafe":
            raise InstallerError("INSTALL_TARGET_UNSAFE", "Install target is a symlink or non-directory path.")
        if existing_state in {"unmanaged", "managed_modified"} and not self.replace_unmanaged:
            raise InstallerError(
                "INSTALL_REPLACEMENT_REQUIRED",
                "Existing skill is unmanaged or locally modified; inspect it, then use --replace-unmanaged explicitly.",
            )

        writable_parent = self.skills_dir
        while not writable_parent.exists() and writable_parent != writable_parent.parent:
            writable_parent = writable_parent.parent
        if not writable_parent.is_dir() or not os.access(writable_parent, os.W_OK):
            raise InstallerError("INSTALL_NOT_WRITABLE", "Codex skills destination is not writable.")
        return git_state, swift_version, swift_target, existing_state

    def _build_release(self) -> Path:
        _run(["swift", "build", "-c", "release"], cwd=self.source_root)
        bin_path = _run(
            ["swift", "build", "-c", "release", "--show-bin-path"],
            cwd=self.source_root,
        ).stdout.strip()
        binary = Path(bin_path) / _binary_name()
        if not binary.is_file():
            raise InstallerError("BUILD_OUTPUT_MISSING", f"Release executable was not found: {binary}")
        return binary

    def _write_manifest(
        self,
        staging: Path,
        git_state: GitState,
        swift_target: SwiftTarget,
    ) -> dict[str, Any]:
        files = {
            relative: _sha256(staging / relative)
            for relative in sorted(_expected_bundle_files(staging))
        }
        manifest = {
            "schema_version": "1",
            "product_version": PRODUCT_VERSION,
            "skill_protocol_version": SKILL_PROTOCOL_VERSION,
            "platform": swift_target.platform,
            "architecture": swift_target.architecture,
            "swift_target_triple": swift_target.triple,
            "source_commit": git_state.commit,
            "source_dirty": git_state.dirty,
            "installed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "files": files,
        }
        (staging / MANIFEST_NAME).write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return manifest

    def _stage(
        self,
        binary: Path,
        git_state: GitState,
        swift_target: SwiftTarget,
        staging: Path,
    ) -> dict[str, Any]:
        staging.mkdir(mode=0o700)
        shutil.copy2(self.skill_source / "SKILL.md", staging / "SKILL.md")
        for source in runtime_files(self.skill_source):
            shutil.copy2(source, staging / source.name)
        bin_dir = staging / "bin"
        bin_dir.mkdir()
        installed_binary = bin_dir / _binary_name()
        shutil.copy2(binary, installed_binary)
        if os.name != "nt":
            installed_binary.chmod(installed_binary.stat().st_mode | 0o111)
            wrapper = staging / "gda_skill.py"
            wrapper.chmod(wrapper.stat().st_mode | 0o111)
        return self._write_manifest(staging, git_state, swift_target)

    def _verify_target_unchanged(self, expected_state: str) -> None:
        current_state = self._existing_state()
        if current_state != expected_state:
            raise InstallerError(
                "INSTALL_TARGET_CHANGED",
                f"Install target changed during build (expected {expected_state}, found {current_state}).",
            )

    def _smoke_bundle(self, skill_dir: Path) -> None:
        issues = validate_skill_dir(skill_dir)
        if issues:
            raise InstallerError("SMOKE_FAILED", issues[0].message)
        verify_manifest(skill_dir)

        binary = skill_dir / "bin" / _binary_name()
        version_raw = _run([str(binary), "version", "--json"], timeout=30).stdout
        version = _decode_version_json(version_raw)
        if version.get("version") != PRODUCT_VERSION:
            raise InstallerError("SMOKE_FAILED", "Staged binary product version does not match installer.")
        if version.get("skill_protocol_version") != SKILL_PROTOCOL_VERSION:
            raise InstallerError("SMOKE_FAILED", "Staged binary protocol version does not match wrapper.")

        _run([str(binary), "--version"], timeout=30)
        _run([str(binary), "--help"], timeout=30)
        _run([str(binary), "help", "lock"], timeout=30)
        # Installer validation must never query a user's credential store: a
        # newly built unsigned binary can trigger a macOS Keychain ACL prompt.
        # Route/help checks prove the auth commands are packaged; real status is
        # reserved for the explicit user-owned adoption and trusted-live gates.
        _run([str(binary), "help", "auth"], timeout=30)
        _run([str(binary), "help", "auth", "status"], timeout=30)

        env = os.environ.copy()
        env["GDA_BIN"] = ""
        env["GDA_DISABLE_AUTH_ONBOARDING"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if os.name != "nt":
            env["PATH"] = "/usr/bin:/bin"
        wrapper_result = _run(
            [sys.executable, str(skill_dir / "gda_skill.py"), "capabilities"],
            cwd=skill_dir,
            env=env,
            timeout=60,
        )
        try:
            payload = json.loads(wrapper_result.stdout)
            resolved = Path(payload["data"]["gda_binary"]).resolve()
        except (json.JSONDecodeError, KeyError, TypeError) as exc:
            raise InstallerError("SMOKE_FAILED", "Wrapper capabilities output is invalid.") from exc
        if resolved != binary.resolve():
            raise InstallerError("SMOKE_FAILED", "Wrapper did not resolve the staged bundled binary.")

    def _acquire_lock(self) -> None:
        try:
            self.lock.mkdir(mode=0o700)
        except FileExistsError as exc:
            raise InstallerError("INSTALL_LOCKED", "Another skill installation appears to be running.") from exc

    def install(self) -> dict[str, Any]:
        git_state, swift_version, swift_target, existing_state = self.preflight()
        runtime = ["SKILL.md", *[path.name for path in runtime_files(self.skill_source)], f"bin/{_binary_name()}"]
        legacy = Path.home() / ".local" / "bin" / _binary_name()
        warnings = []
        if legacy.exists():
            warnings.append(
                f"Legacy shadow binary detected at {legacy}; it was not modified or removed."
            )
        if self.oauth_client_secrets is None:
            warnings.append(
                "This install will not provision Google OAuth. Release owners should pass "
                "--oauth-client-secrets; end users must never be asked for the client JSON."
            )
        plan = {
            "ok": True,
            "dry_run": self.dry_run,
            "source_root": str(self.source_root),
            "target": str(self.target),
            "existing_state": existing_state,
            "source_commit": git_state.commit,
            "source_dirty": git_state.dirty,
            "swift_version": ".".join(map(str, swift_version)),
            "swift_target_triple": swift_target.triple,
            "build_command": ["swift", "build", "-c", "release"],
            "runtime_files": runtime,
            "oauth_client_provisioning": self.oauth_client_secrets is not None,
            "warnings": warnings,
        }
        if self.dry_run:
            return plan

        self.skills_dir.mkdir(parents=True, exist_ok=True)
        self._acquire_lock()
        staging = self.skills_dir / f".{EXPECTED_SKILL_NAME}.install-{uuid.uuid4().hex}"
        backup: Path | None = None
        try:
            binary = self._build_release()
            manifest = self._stage(binary, git_state, swift_target, staging)
            self._smoke_bundle(staging)
            self._verify_target_unchanged(existing_state)

            if self.target.exists():
                backup = self.skills_dir / f".{EXPECTED_SKILL_NAME}.backup-{uuid.uuid4().hex}"
                os.replace(self.target, backup)
            os.replace(staging, self.target)
            try:
                self._smoke_bundle(self.target)
                if self.oauth_client_secrets is not None:
                    _run(
                        [
                            str(self.target / "bin" / _binary_name()),
                            "auth",
                            "oauth-client",
                            "import",
                            "--client-secrets",
                            str(self.oauth_client_secrets),
                            "--json",
                        ],
                        timeout=30,
                    )
            except Exception:
                shutil.rmtree(self.target, ignore_errors=True)
                if backup is not None and backup.exists():
                    os.replace(backup, self.target)
                    backup = None
                raise
            if backup is not None:
                shutil.rmtree(backup)
                backup = None
            plan.update({
                "installed": True,
                "manifest": manifest,
                "manifest_health": "valid",
            })
            return plan
        finally:
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)
            if backup is not None and backup.exists():
                if not self.target.exists():
                    os.replace(backup, self.target)
                else:
                    shutil.rmtree(backup, ignore_errors=True)
            shutil.rmtree(self.lock, ignore_errors=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--codex-home", type=Path, default=None)
    parser.add_argument("--replace-unmanaged", action="store_true")
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument(
        "--oauth-client-secrets",
        type=Path,
        default=None,
        help="Provision GDA's installed-app OAuth client securely after installation.",
    )
    return parser


def main() -> int:
    args = _parser().parse_args()
    codex_home = args.codex_home or Path(os.environ.get("CODEX_HOME", "~/.codex"))
    installer = SkillInstaller(
        source_root=Path(__file__).resolve().parents[1],
        codex_home=codex_home,
        allow_dirty=args.allow_dirty,
        replace_unmanaged=args.replace_unmanaged,
        dry_run=args.dry_run,
        oauth_client_secrets=args.oauth_client_secrets,
    )
    try:
        result = installer.install()
    except InstallerError as exc:
        print(json.dumps({
            "ok": False,
            "error": {"code": exc.code, "message": str(exc)},
        }, indent=2), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
