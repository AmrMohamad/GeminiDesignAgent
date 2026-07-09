from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from gda_constants import DEFAULT_ANALYSIS_REQUEST, HANDOFF_SCHEMA_VERSION
from gda_envelope import GDASkillError, skill_error_payload


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
