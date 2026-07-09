from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from gda_constants import (
    INSTALL_MANIFEST_NAME,
    PRODUCT_VERSION,
    RUNTIME_PYTHON_FILES,
    SKILL_PROTOCOL_VERSION,
)
from gda_envelope import GDASkillError, skill_error_payload


@dataclass(frozen=True)
class GDAResolution:
    path: str
    source: str
    binary_version: str
    protocol_version: str
    manifest_health: str
    warnings: tuple[str, ...] = ()


def _binary_name() -> str:
    return "gda.exe" if os.name == "nt" else "gda"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _protocol_error(
    *,
    binary: Path,
    source: str,
    binary_version: str | None,
    protocol_version: str | None,
    reason: str,
) -> GDASkillError:
    return GDASkillError(
        reason,
        payload=skill_error_payload(
            command="gda.version.handshake",
            code="GDA_PROTOCOL_MISMATCH",
            title="gda wrapper and binary are incompatible",
            message=reason,
            resolution="Reinstall the gemini-design-agent skill from the matching source checkout.",
            diagnostics=[{
                "kind": "gda.compatibility",
                "gda_bin": str(binary),
                "resolution_source": source,
                "wrapper_version": PRODUCT_VERSION,
                "required_protocol_version": SKILL_PROTOCOL_VERSION,
                "binary_version": binary_version,
                "binary_protocol_version": protocol_version,
            }],
            next_actions=[{
                "label": "Reinstall skill",
                "command": "python3 scripts/install_skill.py",
            }],
        ),
    )


def _read_binary_version(binary: Path, source: str) -> tuple[str, str]:
    try:
        proc = subprocess.run(
            [str(binary), "version", "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
            shell=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise _protocol_error(
            binary=binary,
            source=source,
            binary_version=None,
            protocol_version=None,
            reason=f"Could not query gda compatibility metadata: {exc}",
        ) from exc

    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise _protocol_error(
            binary=binary,
            source=source,
            binary_version=None,
            protocol_version=None,
            reason="gda version --json did not return valid JSON.",
        ) from exc

    if proc.returncode != 0:
        raise _protocol_error(
            binary=binary,
            source=source,
            binary_version=None,
            protocol_version=None,
            reason="gda version --json returned a non-zero exit status.",
        )

    metadata = payload.get("data", payload) if isinstance(payload, dict) else {}
    binary_version = metadata.get("version")
    protocol_version = metadata.get("skill_protocol_version")
    if not isinstance(binary_version, str) or not isinstance(protocol_version, str):
        raise _protocol_error(
            binary=binary,
            source=source,
            binary_version=binary_version if isinstance(binary_version, str) else None,
            protocol_version=protocol_version if isinstance(protocol_version, str) else None,
            reason="gda compatibility metadata is missing version or skill_protocol_version.",
        )
    if protocol_version != SKILL_PROTOCOL_VERSION:
        raise _protocol_error(
            binary=binary,
            source=source,
            binary_version=binary_version,
            protocol_version=protocol_version,
            reason=(
                f"Wrapper protocol {SKILL_PROTOCOL_VERSION} is incompatible with "
                f"binary protocol {protocol_version}."
            ),
        )
    return binary_version, protocol_version


def _manifest_runtime_files(skill_dir: Path) -> set[str]:
    return {"SKILL.md", f"bin/{_binary_name()}", *RUNTIME_PYTHON_FILES}


def _bundle_shape(root: Path) -> dict[str, str]:
    shape: dict[str, str] = {}
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError as exc:
            raise GDASkillError(f"Could not enumerate installed skill bundle: {exc}") from exc
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


def _expected_bundle_shape() -> dict[str, str]:
    files = {relative: "file" for relative in _manifest_runtime_files(Path("."))}
    return {
        INSTALL_MANIFEST_NAME: "file",
        "bin": "directory",
        **files,
    }


def verify_install_manifest(skill_dir: Path) -> tuple[str, dict[str, Any] | None]:
    manifest_path = skill_dir / INSTALL_MANIFEST_NAME
    if not manifest_path.exists() and not manifest_path.is_symlink():
        return "absent", None
    actual_shape = _bundle_shape(skill_dir)
    expected_shape = _expected_bundle_shape()
    if actual_shape != expected_shape:
        unexpected = sorted(set(actual_shape) - set(expected_shape))
        missing = sorted(set(expected_shape) - set(actual_shape))
        mismatched = sorted(
            path for path in set(actual_shape) & set(expected_shape)
            if actual_shape[path] != expected_shape[path]
        )
        raise GDASkillError(
            "Installed skill bundle shape is not exact "
            f"(unexpected={unexpected}, missing={missing}, type_mismatch={mismatched})."
        )
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GDASkillError(f"Installed skill manifest is unreadable: {exc}") from exc

    files = manifest.get("files")
    if manifest.get("schema_version") != "1" or not isinstance(files, dict):
        raise GDASkillError("Installed skill manifest has an unsupported schema.")

    expected = _manifest_runtime_files(skill_dir)
    if set(files) != expected:
        raise GDASkillError(
            "Installed skill manifest does not describe the exact runtime bundle."
        )

    for relative, expected_hash in files.items():
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise GDASkillError("Installed skill manifest contains an unsafe path.")
        path = skill_dir / relative_path
        if path.is_symlink() or not path.is_file() or _sha256(path) != expected_hash:
            raise GDASkillError(f"Installed skill file failed manifest verification: {relative}")

    return "valid", manifest


def _candidate_paths() -> list[tuple[Path, str]]:
    candidates: list[tuple[Path, str]] = []
    env_bin = os.environ.get("GDA_BIN", "").strip()
    if env_bin:
        candidates.append((Path(env_bin).expanduser(), "environment"))
        return candidates

    skill_dir = Path(__file__).resolve().parent
    candidates.append((skill_dir / "bin" / _binary_name(), "bundled"))
    candidates.append((skill_dir.parents[1] / ".build" / "release" / _binary_name(), "checkout_release"))
    found = shutil.which("gda")
    if found:
        candidates.append((Path(found), "path"))
    return candidates


def resolve_gda() -> GDAResolution:
    missing_env: Path | None = None
    for candidate, source in _candidate_paths():
        if not candidate.is_file():
            if source == "environment":
                missing_env = candidate
            continue
        if os.name != "nt" and not os.access(candidate, os.X_OK):
            if source == "environment":
                raise GDASkillError(f"GDA_BIN is not executable: {candidate}")
            continue

        manifest_health = "not_applicable"
        manifest: dict[str, Any] | None = None
        warnings: list[str] = []

        if source == "bundled":
            manifest_health, manifest = verify_install_manifest(candidate.parent.parent)
            if manifest is not None:
                manifest_version = manifest.get("product_version")
                manifest_protocol = manifest.get("skill_protocol_version")
                if manifest_version != PRODUCT_VERSION:
                    raise _protocol_error(
                        binary=candidate,
                        source=source,
                        binary_version=None,
                        protocol_version=None,
                        reason=(
                            f"Managed skill manifest version {manifest_version!r} does not match "
                            f"wrapper version {PRODUCT_VERSION}."
                        ),
                    )
                if manifest_protocol != SKILL_PROTOCOL_VERSION:
                    raise _protocol_error(
                        binary=candidate,
                        source=source,
                        binary_version=None,
                        protocol_version=None,
                        reason="Managed skill manifest protocol does not match the wrapper protocol.",
                    )

        # A managed bundled executable is never launched until all bundle hashes
        # have been verified. External overrides necessarily use the handshake
        # itself as their compatibility boundary.
        binary_version, protocol_version = _read_binary_version(candidate, source)

        if source == "bundled":
            if manifest is not None:
                if binary_version != PRODUCT_VERSION:
                    raise _protocol_error(
                        binary=candidate,
                        source=source,
                        binary_version=binary_version,
                        protocol_version=protocol_version,
                        reason=(
                            f"Managed skill requires product version {PRODUCT_VERSION}; "
                            f"binary reports {binary_version!r}."
                        ),
                    )
            elif binary_version != PRODUCT_VERSION:
                warnings.append(
                    "Bundled binary is unmanaged and its product version differs from the wrapper."
                )
        elif binary_version != PRODUCT_VERSION:
            warnings.append(
                f"Selected {source} binary version {binary_version} differs from wrapper version {PRODUCT_VERSION}."
            )

        return GDAResolution(
            path=str(candidate.resolve()),
            source=source,
            binary_version=binary_version,
            protocol_version=protocol_version,
            manifest_health=manifest_health,
            warnings=tuple(warnings),
        )

    if missing_env is not None:
        raise GDASkillError(f"GDA_BIN points to a missing file: {missing_env}")
    raise GDASkillError(
        "Could not find a compatible `gda`. Build the checkout, install it under this skill at bin/gda, "
        "install it on PATH, or set GDA_BIN=/path/to/gda."
    )


def find_gda() -> str:
    return resolve_gda().path


def run_gda(args: list[str], timeout_seconds: int = 180) -> dict[str, Any]:
    resolution = resolve_gda()
    binary = resolution.path

    proc = subprocess.run(
        [binary, *args, "--json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout_seconds,
        shell=False,
    )

    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()

    if not stdout:
        raise GDASkillError(
            "gda returned no JSON",
            payload={
                "ok": False,
                "command": ".".join(args[:2]) if args else "gda",
                "schema_version": "1.0",
                "data": None,
                "diagnostics": [{
                    "kind": "process",
                    "gda_bin": binary,
                    "exit_code": proc.returncode,
                    "stderr": stderr,
                }],
                "next_actions": [],
                "error": {
                    "code": "GDA_NO_JSON",
                    "title": "gda returned no JSON",
                    "message": "The gda process did not write JSON to stdout.",
                    "resolution": "Run the command directly and inspect stderr.",
                    "retryable": True,
                },
            },
        )

    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise GDASkillError(
            "gda stdout was not valid JSON",
            payload={
                "ok": False,
                "command": ".".join(args[:2]) if args else "gda",
                "schema_version": "1.0",
                "data": None,
                "diagnostics": [{
                    "kind": "process",
                    "gda_bin": binary,
                    "exit_code": proc.returncode,
                    "stderr": stderr,
                    "stdout_prefix": stdout[:1000],
                }],
                "next_actions": [],
                "error": {
                    "code": "GDA_INVALID_JSON",
                    "title": "gda stdout was not JSON",
                    "message": str(exc),
                    "resolution": "Ensure the command supports --json and writes no prose to stdout.",
                    "retryable": False,
                },
            },
        ) from exc

    if not isinstance(payload, dict):
        raise GDASkillError(
            "gda stdout had an invalid JSON envelope shape",
            payload=skill_error_payload(
                command=".".join(args[:2]) if args else "gda",
                code="GDA_INVALID_JSON",
                title="gda stdout was not a JSON object",
                message="The gda process returned valid JSON, but not the required object envelope.",
                resolution="Ensure the selected binary implements the current gda JSON protocol.",
                diagnostics=[{
                    "kind": "process",
                    "gda_bin": binary,
                    "exit_code": proc.returncode,
                    "stderr": stderr,
                }],
            ),
        )

    if proc.returncode != 0:
        payload.setdefault("diagnostics", [])
        payload["diagnostics"].append({
            "kind": "process",
            "gda_bin": binary,
            "exit_code": proc.returncode,
            "stderr": stderr,
        })
        raise GDASkillError("gda command failed", payload=payload)

    return payload
