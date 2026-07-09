from __future__ import annotations

from typing import Any


class GDASkillError(RuntimeError):
    def __init__(self, message: str, payload: dict[str, Any] | None = None):
        super().__init__(message)
        self.payload = payload


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
