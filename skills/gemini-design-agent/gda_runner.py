from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from gda_envelope import GDASkillError


def find_gda() -> str:
    env_bin = os.environ.get("GDA_BIN")
    if env_bin:
        path = Path(env_bin).expanduser()
        if path.exists():
            return str(path)
        raise GDASkillError(f"GDA_BIN points to a missing file: {path}")

    bundled = Path(__file__).resolve().parent / "bin" / "gda"
    if bundled.exists():
        return str(bundled)

    found = shutil.which("gda")
    if found:
        return found

    raise GDASkillError(
        "Could not find `gda`. Install it under this skill at bin/gda, install it on PATH, or set GDA_BIN=/path/to/gda."
    )


def run_gda(args: list[str], timeout_seconds: int = 180) -> dict[str, Any]:
    binary = find_gda()

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
