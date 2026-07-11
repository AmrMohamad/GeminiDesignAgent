#!/usr/bin/env python3
"""Create a reproducible, source-only GeminiDesignAgent release archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import zipfile


FORBIDDEN_PARTS = {".git", ".serena", ".DS_Store", "__MACOSX", "__pycache__", ".build", ".swiftpm"}
GATES = [
    [sys.executable, "scripts/build_with_warning_audit.py", "--configuration", "release"],
    [sys.executable, "-m", "unittest", "discover", "-s", "skills/gemini-design-agent/tests", "-p", "test_*.py"],
    [sys.executable, "-m", "unittest", "discover", "-s", "Tests", "-p", "test_*.py"],
    [sys.executable, "scripts/validate_skill.py", "--json"],
    [sys.executable, "scripts/evaluate_design_quality.py", "--mode", "recorded", "--corpus", "public"],
    [sys.executable, "scripts/audit_public_release.py"],
]


def run(command: list[str], cwd: pathlib.Path, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, text=True, check=True, capture_output=capture)


def product_version(root: pathlib.Path) -> str:
    contract = (root / "Sources/GeminiDesignAgentCore/Utilities/GDAContract.swift").read_text(encoding="utf-8")
    match = re.search(r'productVersion\s*=\s*"([^"]+)"', contract)
    if not match:
        raise RuntimeError("Could not read GDAContract.productVersion")
    return match.group(1)


def ensure_clean(root: pathlib.Path) -> None:
    status = run(["git", "status", "--porcelain"], root, capture=True).stdout
    if status.strip():
        raise RuntimeError("Release packaging requires a clean worktree")


def inspect_archive(archive: pathlib.Path, prefix: str) -> list[str]:
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
    if not names or any(not name.startswith(prefix) for name in names):
        raise RuntimeError("Archive entries must use the stable release root prefix")
    forbidden = [
        name for name in names
        if any(part in FORBIDDEN_PARTS for part in pathlib.PurePosixPath(name).parts)
        or name.endswith(".pyc")
        or "/.gda/" in name
    ]
    if forbidden:
        raise RuntimeError(f"Archive contains forbidden entries: {', '.join(forbidden)}")
    return names


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", default="dist")
    parser.add_argument("--skip-gates", action="store_true", help="Only allowed for archive-shape tests; do not use for releases.")
    args = parser.parse_args()

    root = pathlib.Path(__file__).resolve().parents[1]
    if args.version != product_version(root):
        raise SystemExit(f"Requested version {args.version} does not match GDAContract {product_version(root)}")
    ensure_clean(root)
    if not args.skip_gates:
        for gate in GATES:
            run(gate, root)
        run(["git", "diff", "--check"], root)

    output = (root / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"GeminiDesignAgent-{args.version}.zip"
    prefix = f"GeminiDesignAgent-{args.version}/"
    run(["git", "archive", "--format=zip", f"--prefix={prefix}", f"--output={archive}", "HEAD"], root)
    entries = inspect_archive(archive, prefix)
    checksum = sha256(archive)
    sums = output / "SHA256SUMS"
    sums.write_text(f"{checksum}  {archive.name}\n", encoding="utf-8")
    print(json.dumps({"ok": True, "version": args.version, "archive": str(archive), "sha256sums": str(sums), "entry_count": len(entries)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
