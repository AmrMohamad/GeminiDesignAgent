from __future__ import annotations

from typing import Any


class GDASkillError(RuntimeError):
    def __init__(self, message: str, payload: dict[str, Any] | None = None):
        super().__init__(message)
        self.payload = payload


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


def skill_envelope(
    command: str,
    data: dict[str, Any] | list[Any] | None,
    diagnostics: list[dict[str, Any]] | None = None,
    next_actions: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "ok": True,
        "command": command,
        "schema_version": "1.0",
        "data": data,
        "diagnostics": diagnostics or [],
        "next_actions": next_actions or [],
    }

def skill_error_payload(
    command: str,
    code: str,
    title: str,
    message: str,
    resolution: str,
    retryable: bool = False,
    diagnostics: list[dict[str, Any]] | None = None,
    next_actions: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "ok": False,
        "command": command,
        "schema_version": "1.0",
        "data": None,
        "diagnostics": diagnostics or [],
        "next_actions": next_actions or [],
        "error": {
            "code": code,
            "title": title,
            "message": message,
            "resolution": resolution,
            "retryable": retryable,
        },
    }
