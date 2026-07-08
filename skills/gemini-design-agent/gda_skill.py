#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


DEFAULT_ANALYSIS_REQUEST = (
    "Extract layout, spacing, typography, colors, reusable components, "
    "and development-ready implementation values."
)

HANDOFF_SCHEMA_VERSION = "gda.design_handoff.v1"
AUTH_ONBOARDING_URL = "https://aistudio.google.com/app/apikey"
AUTH_ONBOARDING_COOLDOWN_SECONDS = 300


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


def env_flag(name: str) -> bool:
    value = os.environ.get(name)
    return value is not None and value.strip().lower() not in ("", "0", "false", "no", "off")


def auth_onboarding_dir() -> Path:
    uid = getattr(os, "getuid", lambda: "user")()
    return Path(tempfile.gettempdir()) / f"gda-auth-onboarding-{uid}"


def auth_onboarding_marker_path() -> Path:
    return auth_onboarding_dir() / "pending.json"


def read_auth_onboarding_marker() -> dict[str, Any] | None:
    marker = auth_onboarding_marker_path()
    if not marker.exists():
        return None
    try:
        data = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    started_at = data.get("started_at_epoch")
    if not isinstance(started_at, (int, float)):
        return None
    if time.time() - float(started_at) > AUTH_ONBOARDING_COOLDOWN_SECONDS:
        return None
    return data


def auth_onboarding_is_disabled() -> tuple[bool, str | None]:
    if env_flag("GDA_DISABLE_AUTH_ONBOARDING"):
        return True, "GDA_DISABLE_AUTH_ONBOARDING is set"
    if env_flag("GDA_HEADLESS"):
        return True, "GDA_HEADLESS is set"
    if env_flag("CI") or env_flag("GITHUB_ACTIONS"):
        return True, "CI/headless environment detected"
    if os.environ.get("SSH_TTY") or os.environ.get("SSH_CONNECTION"):
        return True, "SSH session detected"
    if sys.platform != "darwin":
        return True, "auto Terminal onboarding is only supported on macOS"
    return False, None


def auth_unavailable_payload(reason: str) -> dict[str, Any]:
    return skill_error_payload(
        command="auth.ensure",
        code="AUTH_ONBOARDING_UNAVAILABLE",
        title="Gemini auth onboarding cannot be opened automatically",
        message=reason,
        resolution="Run `gda auth onboard` in Terminal, or set GEMINI_API_KEY only as a temporary CI/debugging override.",
        retryable=False,
        diagnostics=[{"kind": "auth_onboarding", "reason": reason}],
        next_actions=[
            {"label": "Start auth onboarding", "command": "gda auth onboard"},
            {"label": "Check auth status", "command": "python gda_skill.py ensure-auth"},
        ],
    )


def write_auth_onboarding_launcher(gda_binary: str) -> Path:
    launch_dir = auth_onboarding_dir()
    launch_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    launcher = launch_dir / "gda-auth-onboard.command"
    quoted_binary = shlex.quote(gda_binary)
    launcher.write_text(
        "\n".join([
            "#!/bin/zsh",
            "clear",
            "echo 'Gemini Design Agent auth onboarding'",
            "echo ''",
            f"{quoted_binary} auth onboard",
            "status=$?",
            "echo ''",
            "if [ $status -eq 0 ]; then",
            "  echo 'Done. Return to Codex and rerun the design analysis.'",
            "else",
            f"  echo 'Auth onboarding did not complete. Retry with: {quoted_binary} auth onboard'",
            "fi",
            "echo ''",
            "read -r '?Press Return to close this window...'",
            "exit $status",
            "",
        ]),
        encoding="utf-8",
    )
    launcher.chmod(0o700)
    return launcher


def launch_auth_onboarding_terminal(force: bool = False) -> dict[str, Any]:
    marker = read_auth_onboarding_marker()
    if marker and not force:
        raise GDASkillError(
            "auth onboarding was already started recently",
            payload=skill_error_payload(
                command="auth.ensure",
                code="AUTH_ONBOARDING_ALREADY_STARTED",
                title="Gemini auth onboarding is already in progress",
                message="A Terminal onboarding window was opened recently. Finish that flow, then rerun the analysis.",
                resolution="Complete the Terminal prompt, or rerun ensure-auth with --force to reopen it.",
                retryable=True,
                diagnostics=[{"kind": "auth_onboarding", "marker": marker}],
                next_actions=[
                    {"label": "Check auth status", "command": "python gda_skill.py ensure-auth"},
                    {"label": "Reopen onboarding", "command": "python gda_skill.py ensure-auth --force"},
                ],
            ),
        )

    disabled, reason = auth_onboarding_is_disabled()
    if disabled:
        raise GDASkillError("auth onboarding cannot be opened", payload=auth_unavailable_payload(reason or "onboarding is disabled"))

    gda_binary = find_gda()
    launcher = write_auth_onboarding_launcher(gda_binary)
    proc = subprocess.run(
        ["open", "-a", "Terminal", str(launcher)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        shell=False,
        timeout=30,
    )
    if proc.returncode != 0:
        raise GDASkillError(
            "failed to open Terminal for auth onboarding",
            payload=skill_error_payload(
                command="auth.ensure",
                code="AUTH_ONBOARDING_LAUNCH_FAILED",
                title="Could not open Terminal for Gemini auth onboarding",
                message=proc.stderr.strip() or "The macOS `open` command failed.",
                resolution="Run `gda auth onboard` manually in Terminal.",
                retryable=True,
                diagnostics=[{
                    "kind": "process",
                    "exit_code": proc.returncode,
                    "stderr": proc.stderr.strip(),
                    "launcher_path": str(launcher),
                    "gda_bin": gda_binary,
                }],
                next_actions=[{"label": "Start auth onboarding", "command": "gda auth onboard"}],
            ),
        )

    marker_data = {
        "started_at_epoch": time.time(),
        "launcher_path": str(launcher),
        "gda_bin": gda_binary,
    }
    auth_onboarding_marker_path().write_text(json.dumps(marker_data, indent=2, sort_keys=True), encoding="utf-8")
    raise GDASkillError(
        "auth onboarding started",
        payload=skill_error_payload(
            command="auth.ensure",
            code="AUTH_ONBOARDING_STARTED",
            title="Gemini auth onboarding started",
            message="A Terminal window was opened to configure the Gemini API key.",
            resolution="Complete the Terminal prompt, then rerun the original design analysis.",
            retryable=True,
            diagnostics=[{"kind": "auth_onboarding", **marker_data}],
            next_actions=[
                {"label": "Check auth status", "command": "python gda_skill.py ensure-auth"},
                {"label": "Rerun original analysis", "command": "Rerun the previous gemini-design-agent command after auth is configured"},
            ],
        ),
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


def get_path(value: Any, dotted_path: str) -> Any:
    current = value
    for part in dotted_path.split("."):
        if not isinstance(current, dict) or part not in current:
            return None
        current = current[part]
    return current


def first_path(value: Any, dotted_paths: list[str]) -> Any:
    for path in dotted_paths:
        found = get_path(value, path)
        if found not in (None, ""):
            return found
    return None


def as_string(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def as_float(value: Any) -> float | None:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def load_handoff_json(path: str) -> dict[str, Any]:
    if path == "-":
        raw = sys.stdin.read()
    else:
        raw = Path(path).expanduser().read_text(encoding="utf-8")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise GDASkillError(
            "handoff JSON was not valid",
            payload=skill_error_payload(
                command="handoff.validate",
                code="HANDOFF_INVALID_JSON",
                title="Design handoff JSON is invalid",
                message=str(exc),
                resolution="Pass a valid JSON object, or use '-' to read the JSON object from stdin.",
            ),
        ) from exc
    if not isinstance(payload, dict):
        raise GDASkillError(
            "handoff JSON must be an object",
            payload=skill_error_payload(
                command="handoff.validate",
                code="HANDOFF_NOT_OBJECT",
                title="Design handoff JSON must be an object",
                message="The handoff payload root was not a JSON object.",
                resolution="Wrap the design handoff data in a JSON object with source, asset, analysis, and context fields.",
            ),
        )
    return payload


def platform_slug(value: Any) -> str:
    text = as_string(value) or "unknown"
    normalized = text.lower().replace(" ", "_").replace("-", "_")
    aliases = {
        "figma_mcp": "figma",
        "figma_rest": "figma",
        "figma_desktop": "figma",
        "fig": "figma",
        "open_design": "open_design",
        "opendesign": "open_design",
        "adobe_xd": "adobe_xd",
        "xd": "adobe_xd",
    }
    return aliases.get(normalized, normalized)


def summarize_collection(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return {"type": "object", "keys": sorted(value.keys())[:24], "count": len(value)}
    if isinstance(value, list):
        return {"type": "array", "count": len(value)}
    if value is None:
        return {"type": "missing", "count": 0}
    return {"type": type(value).__name__, "count": 1}


def normalize_handoff(raw: dict[str, Any]) -> dict[str, Any]:
    payload = raw.get("handoff") if isinstance(raw.get("handoff"), dict) else raw
    source = payload.get("source") if isinstance(payload.get("source"), dict) else {}
    asset = payload.get("asset") if isinstance(payload.get("asset"), dict) else {}
    analysis = payload.get("analysis") if isinstance(payload.get("analysis"), dict) else {}
    context = payload.get("context") if isinstance(payload.get("context"), dict) else {}
    target = payload.get("target") if isinstance(payload.get("target"), dict) else {}

    image = first_path(payload, [
        "asset.image_path",
        "asset.path",
        "asset.local_path",
        "image.path",
        "image.image_path",
        "screenshot.path",
        "screenshot.image_path",
        "screenshot_path",
        "image_path",
        "png",
    ])
    screen = first_path(payload, [
        "analysis.screen",
        "analysis.screen_name",
        "target.name",
        "target.node_name",
        "source.node_name",
        "source.frame_name",
        "node.name",
        "screen",
        "screen_name",
    ])
    if not screen and image:
        screen = Path(str(image)).stem

    platform = platform_slug(first_path(payload, [
        "source.platform",
        "source.kind",
        "platform",
    ]))
    mode = as_string(first_path(payload, [
        "source.mode",
        "source.transport",
        "source.connector",
    ]))

    normalized = {
        "schema_version": HANDOFF_SCHEMA_VERSION,
        "source": {
            "platform": platform,
            "mode": mode,
            "tool": as_string(first_path(payload, ["source.tool", "source.mcp_tool", "tool"])),
            "url": as_string(first_path(payload, ["source.url", "url", "figma_url"])),
            "file_key": as_string(first_path(payload, ["source.file_key", "source.fileKey", "file_key", "fileKey"])),
            "node_id": as_string(first_path(payload, ["source.node_id", "source.nodeId", "node_id", "nodeId", "target.node_id"])),
            "node_name": as_string(first_path(payload, ["source.node_name", "target.node_name", "target.name", "node.name"])),
        },
        "analysis": {
            "project_dir": as_string(first_path(payload, ["analysis.project_dir", "project_dir"])),
            "image": as_string(image),
            "screen": as_string(screen),
            "request": as_string(first_path(payload, ["analysis.request", "request"])) or DEFAULT_ANALYSIS_REQUEST,
            "preset": as_string(first_path(payload, ["analysis.preset", "preset"])),
            "model": as_string(first_path(payload, ["analysis.model", "model"])),
            "device_pixel_ratio": as_float(first_path(payload, [
                "analysis.device_pixel_ratio",
                "analysis.dpr",
                "asset.device_pixel_ratio",
                "asset.scale",
                "image.scale",
                "screenshot.scale",
            ])),
            "viewport": as_string(first_path(payload, ["analysis.viewport", "asset.viewport", "context.viewport", "viewport"])),
            "theme": as_string(first_path(payload, ["analysis.theme", "context.theme", "theme"])),
            "state": as_string(first_path(payload, ["analysis.state", "context.state", "state"])),
            "locale_direction": as_string(first_path(payload, [
                "analysis.locale_direction",
                "analysis.direction",
                "context.locale_direction",
                "context.direction",
                "direction",
            ])),
        },
        "context_summary": {
            "tokens": summarize_collection(context.get("tokens") or payload.get("tokens")),
            "metadata": summarize_collection(context.get("metadata") or payload.get("metadata")),
            "layout_tree": summarize_collection(context.get("layout_tree") or payload.get("layout_tree")),
            "interactions": summarize_collection(context.get("interactions") or payload.get("interactions")),
            "assets": summarize_collection(context.get("assets") or asset.get("assets")),
        },
        "raw_context": context,
    }

    diagnostics: list[dict[str, Any]] = []
    if target:
        diagnostics.append({"kind": "handoff.target", "target": target})
    if asset:
        diagnostics.append({"kind": "handoff.asset", "asset": {k: v for k, v in asset.items() if k != "data"}})
    normalized["diagnostics"] = diagnostics
    return normalized


def validate_normalized_handoff(normalized: dict[str, Any]) -> tuple[bool, list[dict[str, Any]]]:
    issues: list[dict[str, Any]] = []
    analysis_data = normalized["analysis"]

    image = analysis_data.get("image")
    if not image:
        issues.append({
            "field": "asset.image_path",
            "severity": "error",
            "message": "A design handoff must include a local screenshot/image path.",
        })
    else:
        image_path = Path(str(image)).expanduser()
        if not image_path.is_absolute():
            issues.append({
                "field": "asset.image_path",
                "severity": "warning",
                "message": "Image path is relative; absolute paths are safer for cross-skill handoff.",
            })
        if not image_path.exists():
            issues.append({
                "field": "asset.image_path",
                "severity": "error",
                "message": f"Image file does not exist: {image_path}",
            })

    if not analysis_data.get("screen"):
        issues.append({
            "field": "analysis.screen",
            "severity": "error",
            "message": "A design handoff must include a screen, frame, component, or node name.",
        })

    platform = normalized["source"].get("platform")
    if platform == "unknown":
        issues.append({
            "field": "source.platform",
            "severity": "warning",
            "message": "Source platform is unknown; analysis can continue, but memory will be less traceable.",
        })

    return not any(issue["severity"] == "error" for issue in issues), issues


def compact_json(value: Any, max_chars: int) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True)
    if len(encoded) <= max_chars:
        return encoded
    return encoded[:max_chars] + "...[truncated]"


def build_handoff_request(
    normalized: dict[str, Any],
    request_override: str | None = None,
    include_context: bool = True,
    max_context_chars: int = 6000,
) -> str:
    analysis_data = normalized["analysis"]
    source = normalized["source"]
    base_request = request_override or analysis_data.get("request") or DEFAULT_ANALYSIS_REQUEST

    lines = [
        base_request,
        "",
        "Design platform handoff context:",
        f"- source_platform: {source.get('platform') or 'unknown'}",
    ]
    for key in ["mode", "tool", "file_key", "node_id", "node_name", "url"]:
        value = source.get(key)
        if value:
            lines.append(f"- {key}: {value}")
    for key in ["viewport", "theme", "state", "locale_direction", "device_pixel_ratio"]:
        value = analysis_data.get(key)
        if value:
            lines.append(f"- {key}: {value}")

    lines.extend([
        "",
        "Use the screenshot as the visual source of truth.",
        "Use platform metadata as traceability and disambiguation hints, not as a replacement for visible evidence.",
    ])

    if include_context:
        context_payload = {
            "context_summary": normalized.get("context_summary"),
            "context": normalized.get("raw_context"),
        }
        lines.extend([
            "",
            "Structured handoff metadata JSON:",
            compact_json(context_payload, max_context_chars),
        ])

    return "\n".join(lines)


def capabilities() -> dict[str, Any]:
    return skill_envelope(
        command="capabilities",
        data={
            "skill": "gemini-design-agent",
            "handoff_schema_version": HANDOFF_SCHEMA_VERSION,
            "gda_binary": find_gda(),
            "input_modes": [
                "direct_screenshot",
                "design_handoff_json",
                "batch_file",
                "memory_preview",
                "memory_explain",
            ],
            "compatible_sources": [
                "figma_mcp",
                "figma_rest_image_export",
                "open_design",
                "local_fig_decoder",
                "browser_or_app_screenshot",
                "sketch_or_adobe_xd_export",
                "any_tool_that_can_write_a_local_png_or_jpeg",
            ],
            "handoff_required_fields": [
                "asset.image_path",
                "analysis.screen or target.name or source.node_name",
            ],
            "handoff_optional_fields": [
                "source.platform",
                "source.url",
                "source.file_key",
                "source.node_id",
                "asset.scale",
                "analysis.viewport",
                "analysis.theme",
                "analysis.state",
                "analysis.locale_direction",
                "context.tokens",
                "context.metadata",
                "context.layout_tree",
                "context.interactions",
            ],
        },
        next_actions=[
            {"label": "Validate handoff", "command": "python gda_skill.py validate-handoff --handoff-json handoff.json"},
            {"label": "Analyze handoff", "command": "python gda_skill.py analyze-handoff --handoff-json handoff.json"},
        ],
    )


def validate_handoff(handoff_json: str) -> dict[str, Any]:
    normalized = normalize_handoff(load_handoff_json(handoff_json))
    valid, issues = validate_normalized_handoff(normalized)
    return skill_envelope(
        command="handoff.validate",
        data={
            "valid": valid,
            "handoff": {k: v for k, v in normalized.items() if k != "raw_context"},
            "issues": issues,
        },
        next_actions=[] if valid else [{
            "label": "Fix handoff JSON",
            "command": "Add asset.image_path and analysis.screen, then rerun validate-handoff",
        }],
    )


def analyze_handoff(
    handoff_json: str,
    project_dir: str | None = None,
    request: str | None = None,
    screen: str | None = None,
    preset: str | None = None,
    model: str | None = None,
    include_context: bool = True,
    max_context_chars: int = 6000,
    timeout_seconds: int = 180,
) -> dict[str, Any]:
    normalized = normalize_handoff(load_handoff_json(handoff_json))
    valid, issues = validate_normalized_handoff(normalized)
    if not valid:
        raise GDASkillError(
            "handoff is missing required fields",
            payload=skill_error_payload(
                command="handoff.analyze",
                code="HANDOFF_INVALID",
                title="Design handoff is not analyzable",
                message="The handoff JSON is missing required fields or points to a missing image.",
                resolution="Run validate-handoff, fix all error-severity issues, then retry.",
                diagnostics=[{"kind": "handoff.validation", "issues": issues}],
                next_actions=[{"label": "Validate handoff", "command": "python gda_skill.py validate-handoff --handoff-json <path>"}],
            ),
        )

    analysis_data = normalized["analysis"]
    result = analyze(
        image=str(analysis_data["image"]),
        screen=screen or str(analysis_data["screen"]),
        request=build_handoff_request(
            normalized=normalized,
            request_override=request,
            include_context=include_context,
            max_context_chars=max_context_chars,
        ),
        project_dir=project_dir or analysis_data.get("project_dir") or ".gda",
        model=model or analysis_data.get("model"),
        preset=preset or analysis_data.get("preset"),
        device_pixel_ratio=analysis_data.get("device_pixel_ratio"),
        viewport=analysis_data.get("viewport"),
        theme=analysis_data.get("theme"),
        state=analysis_data.get("state"),
        locale_direction=analysis_data.get("locale_direction"),
        timeout_seconds=timeout_seconds,
    )
    result.setdefault("diagnostics", [])
    result["diagnostics"].append({
        "kind": "design_handoff",
        "schema_version": HANDOFF_SCHEMA_VERSION,
        "source": normalized["source"],
        "context_summary": normalized["context_summary"],
    })
    return result


def analyze(
    image: str,
    screen: str,
    request: str,
    project_dir: str = ".gda",
    model: str | None = None,
    preset: str | None = None,
    device_pixel_ratio: float | None = None,
    viewport: str | None = None,
    theme: str | None = None,
    state: str | None = None,
    locale_direction: str | None = None,
    timeout_seconds: int = 180,
) -> dict[str, Any]:
    image_path = Path(image).expanduser().resolve()
    if not image_path.exists():
        raise FileNotFoundError(f"Image not found: {image_path}")

    ensure_auth()

    args = [
        "analyze",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--image", str(image_path),
        "--screen", screen,
        "--request", request,
    ]

    if model:
        args.extend(["--model", model])
    if preset:
        args.extend(["--preset", preset])
    if device_pixel_ratio:
        args.extend(["--device-pixel-ratio", str(device_pixel_ratio)])
    if viewport:
        args.extend(["--viewport", viewport])
    if theme:
        args.extend(["--theme", theme])
    if state:
        args.extend(["--state", state])
    if locale_direction:
        args.extend(["--locale-direction", locale_direction])

    return run_gda(args, timeout_seconds=timeout_seconds)


def analyze_batch(
    batch_file: str,
    project_dir: str = ".gda",
    request: str = (
        "Extract layout, spacing, typography, colors, reusable components, "
        "and development-ready implementation values."
    ),
    preset: str | None = None,
    timeout_seconds: int = 600,
) -> dict[str, Any]:
    batch_path = Path(batch_file).expanduser().resolve()
    if not batch_path.exists():
        raise FileNotFoundError(f"Batch file not found: {batch_path}")

    ensure_auth()

    args = [
        "analyze",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--batch-file", str(batch_path),
        "--request", request,
    ]
    if preset:
        args.extend(["--preset", preset])

    return run_gda(args, timeout_seconds=timeout_seconds)


def setup(
    project_dir: str = ".gda",
    project_name: str = "Design Project",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "setup",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--project-name", project_name,
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def compare(
    before: str,
    after: str,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "compare",
        "--before", str(Path(before).expanduser().resolve()),
        "--after", str(Path(after).expanduser().resolve()),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def memory_search(
    query: str,
    project_dir: str = ".gda",
    limit: int = 8,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "memory",
        "search",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--query", query,
        "--limit", str(limit),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def memory_show(
    atom_id: str,
    project_dir: str = ".gda",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "memory",
        "show",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--id", atom_id,
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def memory_export(
    project_dir: str = ".gda",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "memory",
        "export",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def memory_preview(
    screen: str,
    request: str,
    project_dir: str = ".gda",
    limit: int = 8,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "memory",
        "preview",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--screen", screen,
        "--request", request,
        "--limit", str(limit),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def memory_explain(
    run_id: str,
    project_dir: str = ".gda",
    limit: int = 8,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "memory",
        "explain",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--run-id", run_id,
        "--limit", str(limit),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def memory_conflicts(
    project_dir: str = ".gda",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "memory",
        "conflicts",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def compact(
    project_dir: str = ".gda",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "compact",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def gc(
    project_dir: str = ".gda",
    max_raw_refs_age_days: int = 90,
    expire_low_confidence_older_than_days: int | None = None,
    min_confidence: float | None = None,
    apply: bool = False,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "gc",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--max-raw-refs-age-days", str(max_raw_refs_age_days),
    ]
    if expire_low_confidence_older_than_days is not None:
        args.extend([
            "--expire-low-confidence-older-than-days",
            str(expire_low_confidence_older_than_days),
        ])
    if min_confidence is not None:
        args.extend(["--min-confidence", str(min_confidence)])
    if apply:
        args.append("--apply")

    return run_gda(args, timeout_seconds=timeout_seconds)


def runs_list(
    project_dir: str = ".gda",
    limit: int = 25,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "runs",
        "list",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--limit", str(limit),
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def runs_show(
    run_id: str,
    project_dir: str = ".gda",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "runs",
        "show",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--id", run_id,
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def runs_undo(
    run_id: str,
    project_dir: str = ".gda",
    confirm: bool = False,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "runs",
        "undo",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--id", run_id,
    ]
    if confirm:
        args.append("--confirm")

    return run_gda(args, timeout_seconds=timeout_seconds)


def runs_recover(
    run_id: str,
    project_dir: str = ".gda",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "runs",
        "recover",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--id", run_id,
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def export(
    project_dir: str = ".gda",
    format: str = "json",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "export",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--format", format,
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def snapshot(
    action: str,
    project_dir: str = ".gda",
    name: str | None = None,
    snapshot_id: str | None = None,
    confirm: bool = False,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "snapshot",
        action,
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
    ]
    if name:
        args.extend(["--name", name])
    if snapshot_id:
        args.extend(["--id", snapshot_id])
    if confirm:
        args.append("--confirm")

    return run_gda(args, timeout_seconds=timeout_seconds)


def doctor(
    project_dir: str = ".gda",
    image: str | None = None,
    model: str | None = None,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "doctor",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
    ]
    if image:
        args.extend(["--image", str(Path(image).expanduser().resolve())])
    if model:
        args.extend(["--model", model])

    return run_gda(args, timeout_seconds=timeout_seconds)


def auth_status(timeout_seconds: int = 60) -> dict[str, Any]:
    return run_gda(["auth", "status"], timeout_seconds=timeout_seconds)


def ensure_auth(
    auto_open_terminal: bool = True,
    force: bool = False,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    env_key = os.environ.get("GEMINI_API_KEY")
    if env_key and env_key.strip():
        return skill_envelope(
            command="auth.ensure",
            data={
                "usable": True,
                "source": "environment",
                "keychain_configured": None,
            },
            diagnostics=[{
                "kind": "auth",
                "status": "warn",
                "message": "GEMINI_API_KEY is set as a temporary override.",
                "resolution": "Run `gda auth onboard` for persistent local Keychain setup.",
            }],
            next_actions=[{"label": "Save API key to Keychain", "command": "gda auth onboard"}],
        )

    status = auth_status(timeout_seconds=timeout_seconds)
    configured = bool((status.get("data") or {}).get("configured"))
    if configured:
        return skill_envelope(
            command="auth.ensure",
            data={
                "usable": True,
                "source": "keychain",
                "keychain_configured": True,
            },
        )

    if not auto_open_terminal:
        raise GDASkillError(
            "gemini auth is not configured",
            payload=auth_unavailable_payload("auto-opening Terminal was disabled for this call"),
        )

    return launch_auth_onboarding_terminal(force=force)


def init_project(
    project_dir: str = ".gda",
    project_name: str = "Design Project",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "init",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--project-name", project_name,
    ]

    return run_gda(args, timeout_seconds=timeout_seconds)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Python wrapper for Gemini Design Agent CLI."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init")
    p_init.add_argument("--project-dir", default=".gda")
    p_init.add_argument("--project-name", default="Design Project")

    p_analyze = sub.add_parser("analyze")
    p_analyze.add_argument("--image", required=True)
    p_analyze.add_argument("--screen", required=True)
    p_analyze.add_argument("--request", default=DEFAULT_ANALYSIS_REQUEST)
    p_analyze.add_argument("--project-dir", default=".gda")
    p_analyze.add_argument("--model", default=None)
    p_analyze.add_argument("--preset", default=None)
    p_analyze.add_argument("--device-pixel-ratio", type=float, default=None)
    p_analyze.add_argument("--viewport", default=None)
    p_analyze.add_argument("--theme", default=None)
    p_analyze.add_argument("--state", default=None)
    p_analyze.add_argument("--locale-direction", default=None)
    p_analyze.add_argument("--timeout-seconds", type=int, default=180)

    p_batch = sub.add_parser("analyze-batch")
    p_batch.add_argument("--batch-file", required=True)
    p_batch.add_argument("--project-dir", default=".gda")
    p_batch.add_argument("--request", default=DEFAULT_ANALYSIS_REQUEST)
    p_batch.add_argument("--preset", default=None)
    p_batch.add_argument("--timeout-seconds", type=int, default=600)

    sub.add_parser("capabilities")

    p_validate_handoff = sub.add_parser("validate-handoff")
    p_validate_handoff.add_argument("--handoff-json", required=True, help="Path to design handoff JSON, or '-' for stdin")

    p_analyze_handoff = sub.add_parser("analyze-handoff")
    p_analyze_handoff.add_argument("--handoff-json", required=True, help="Path to design handoff JSON, or '-' for stdin")
    p_analyze_handoff.add_argument("--project-dir", default=None)
    p_analyze_handoff.add_argument("--screen", default=None)
    p_analyze_handoff.add_argument("--request", default=None)
    p_analyze_handoff.add_argument("--preset", default=None)
    p_analyze_handoff.add_argument("--model", default=None)
    p_analyze_handoff.add_argument("--max-context-chars", type=int, default=6000)
    p_analyze_handoff.add_argument("--no-handoff-context", action="store_true")
    p_analyze_handoff.add_argument("--timeout-seconds", type=int, default=180)

    p_setup = sub.add_parser("setup")
    p_setup.add_argument("--project-dir", default=".gda")
    p_setup.add_argument("--project-name", default="Design Project")

    p_compare = sub.add_parser("compare")
    p_compare.add_argument("--before", required=True)
    p_compare.add_argument("--after", required=True)

    p_search = sub.add_parser("memory-search")
    p_search.add_argument("--query", required=True)
    p_search.add_argument("--project-dir", default=".gda")
    p_search.add_argument("--limit", type=int, default=8)

    p_show = sub.add_parser("memory-show")
    p_show.add_argument("--id", required=True)
    p_show.add_argument("--project-dir", default=".gda")

    p_export = sub.add_parser("memory-export")
    p_export.add_argument("--project-dir", default=".gda")

    p_preview = sub.add_parser("memory-preview")
    p_preview.add_argument("--screen", required=True)
    p_preview.add_argument("--request", required=True)
    p_preview.add_argument("--project-dir", default=".gda")
    p_preview.add_argument("--limit", type=int, default=8)

    p_explain = sub.add_parser("memory-explain")
    p_explain.add_argument("--run-id", required=True)
    p_explain.add_argument("--project-dir", default=".gda")
    p_explain.add_argument("--limit", type=int, default=8)

    p_conflicts = sub.add_parser("memory-conflicts")
    p_conflicts.add_argument("--project-dir", default=".gda")

    p_compact = sub.add_parser("compact")
    p_compact.add_argument("--project-dir", default=".gda")

    p_gc = sub.add_parser("gc")
    p_gc.add_argument("--project-dir", default=".gda")
    p_gc.add_argument("--max-raw-refs-age-days", type=int, default=90)
    p_gc.add_argument("--expire-low-confidence-older-than-days", type=int, default=None)
    p_gc.add_argument("--min-confidence", type=float, default=None)
    p_gc.add_argument("--apply", action="store_true")

    p_runs_list = sub.add_parser("runs-list")
    p_runs_list.add_argument("--project-dir", default=".gda")
    p_runs_list.add_argument("--limit", type=int, default=25)

    p_runs_show = sub.add_parser("runs-show")
    p_runs_show.add_argument("--id", required=True)
    p_runs_show.add_argument("--project-dir", default=".gda")

    p_runs_undo = sub.add_parser("runs-undo")
    p_runs_undo.add_argument("--id", required=True)
    p_runs_undo.add_argument("--project-dir", default=".gda")
    p_runs_undo.add_argument("--confirm", action="store_true")

    p_runs_recover = sub.add_parser("runs-recover")
    p_runs_recover.add_argument("--id", required=True)
    p_runs_recover.add_argument("--project-dir", default=".gda")

    p_top_export = sub.add_parser("export")
    p_top_export.add_argument("--project-dir", default=".gda")
    p_top_export.add_argument("--format", default="json")

    p_snapshot = sub.add_parser("snapshot")
    p_snapshot.add_argument("action", choices=["create", "list", "show", "restore"])
    p_snapshot.add_argument("--project-dir", default=".gda")
    p_snapshot.add_argument("--name", default=None)
    p_snapshot.add_argument("--id", default=None)
    p_snapshot.add_argument("--confirm", action="store_true")

    p_doctor = sub.add_parser("doctor")
    p_doctor.add_argument("--project-dir", default=".gda")
    p_doctor.add_argument("--image", default=None)
    p_doctor.add_argument("--model", default=None)

    sub.add_parser("auth-status")

    p_ensure_auth = sub.add_parser("ensure-auth")
    p_ensure_auth.add_argument("--no-open-terminal", action="store_true")
    p_ensure_auth.add_argument("--force", action="store_true")

    ns = parser.parse_args()

    try:
        if ns.command == "init":
            result = init_project(
                project_dir=ns.project_dir,
                project_name=ns.project_name,
            )
        elif ns.command == "analyze":
            result = analyze(
                image=ns.image,
                screen=ns.screen,
                request=ns.request,
                project_dir=ns.project_dir,
                model=ns.model,
                preset=ns.preset,
                device_pixel_ratio=ns.device_pixel_ratio,
                viewport=ns.viewport,
                theme=ns.theme,
                state=ns.state,
                locale_direction=ns.locale_direction,
                timeout_seconds=ns.timeout_seconds,
            )
        elif ns.command == "capabilities":
            result = capabilities()
        elif ns.command == "validate-handoff":
            result = validate_handoff(handoff_json=ns.handoff_json)
        elif ns.command == "analyze-handoff":
            result = analyze_handoff(
                handoff_json=ns.handoff_json,
                project_dir=ns.project_dir,
                request=ns.request,
                screen=ns.screen,
                preset=ns.preset,
                model=ns.model,
                include_context=not ns.no_handoff_context,
                max_context_chars=ns.max_context_chars,
                timeout_seconds=ns.timeout_seconds,
            )
        elif ns.command == "analyze-batch":
            result = analyze_batch(
                batch_file=ns.batch_file,
                project_dir=ns.project_dir,
                request=ns.request,
                preset=ns.preset,
                timeout_seconds=ns.timeout_seconds,
            )
        elif ns.command == "setup":
            result = setup(
                project_dir=ns.project_dir,
                project_name=ns.project_name,
            )
        elif ns.command == "compare":
            result = compare(
                before=ns.before,
                after=ns.after,
            )
        elif ns.command == "memory-search":
            result = memory_search(
                query=ns.query,
                project_dir=ns.project_dir,
                limit=ns.limit,
            )
        elif ns.command == "memory-show":
            result = memory_show(
                atom_id=ns.id,
                project_dir=ns.project_dir,
            )
        elif ns.command == "memory-export":
            result = memory_export(project_dir=ns.project_dir)
        elif ns.command == "memory-preview":
            result = memory_preview(
                screen=ns.screen,
                request=ns.request,
                project_dir=ns.project_dir,
                limit=ns.limit,
            )
        elif ns.command == "memory-explain":
            result = memory_explain(
                run_id=ns.run_id,
                project_dir=ns.project_dir,
                limit=ns.limit,
            )
        elif ns.command == "memory-conflicts":
            result = memory_conflicts(project_dir=ns.project_dir)
        elif ns.command == "compact":
            result = compact(project_dir=ns.project_dir)
        elif ns.command == "gc":
            result = gc(
                project_dir=ns.project_dir,
                max_raw_refs_age_days=ns.max_raw_refs_age_days,
                expire_low_confidence_older_than_days=ns.expire_low_confidence_older_than_days,
                min_confidence=ns.min_confidence,
                apply=ns.apply,
            )
        elif ns.command == "runs-list":
            result = runs_list(
                project_dir=ns.project_dir,
                limit=ns.limit,
            )
        elif ns.command == "runs-show":
            result = runs_show(
                run_id=ns.id,
                project_dir=ns.project_dir,
            )
        elif ns.command == "runs-undo":
            result = runs_undo(
                run_id=ns.id,
                project_dir=ns.project_dir,
                confirm=ns.confirm,
            )
        elif ns.command == "runs-recover":
            result = runs_recover(
                run_id=ns.id,
                project_dir=ns.project_dir,
            )
        elif ns.command == "export":
            result = export(
                project_dir=ns.project_dir,
                format=ns.format,
            )
        elif ns.command == "snapshot":
            result = snapshot(
                action=ns.action,
                project_dir=ns.project_dir,
                name=ns.name,
                snapshot_id=ns.id,
                confirm=ns.confirm,
            )
        elif ns.command == "doctor":
            result = doctor(
                project_dir=ns.project_dir,
                image=ns.image,
                model=ns.model,
            )
        elif ns.command == "auth-status":
            result = auth_status()
        elif ns.command == "ensure-auth":
            result = ensure_auth(
                auto_open_terminal=not ns.no_open_terminal,
                force=ns.force,
            )
        else:
            raise GDASkillError(f"Unsupported command: {ns.command}")

        print(json.dumps(result, indent=2, ensure_ascii=False))

    except GDASkillError as exc:
        payload = exc.payload if exc.payload is not None else {
            "ok": False,
            "command": "gda_skill",
            "schema_version": "1.0",
            "data": None,
            "diagnostics": [],
            "next_actions": [],
            "error": {
                "code": "GDA_SKILL_ERROR",
                "title": "gda skill wrapper failed",
                "message": str(exc),
                "resolution": "Check GDA_BIN or install the gda binary.",
                "retryable": False,
            },
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        sys.exit(1)

    except Exception as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "command": "gda_skill",
                    "schema_version": "1.0",
                    "data": None,
                    "diagnostics": [],
                    "next_actions": [],
                    "error": {
                        "code": "GDA_SKILL_ERROR",
                        "title": "gda skill wrapper failed",
                        "message": str(exc),
                        "resolution": "Check wrapper arguments and local file paths.",
                        "retryable": False,
                    },
                },
                indent=2,
                ensure_ascii=False,
            )
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
