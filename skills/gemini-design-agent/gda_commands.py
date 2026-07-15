from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from gda_auth import auth_unavailable_payload, launch_auth_onboarding_terminal
from gda_constants import (
    ANALYSIS_SCHEMA_VERSION,
    DATABASE_SCHEMA_VERSION,
    DEFAULT_ANALYSIS_REQUEST,
    GEMINI_API_VERSION,
    HANDOFF_SCHEMA_VERSION,
    PRODUCT_VERSION,
    PROMPT_SCHEMA_VERSION,
    SKILL_PROTOCOL_VERSION,
)
from gda_envelope import GDASkillError, skill_envelope, skill_error_payload
from gda_handoff import (
    build_handoff_request,
    load_handoff_json,
    normalize_handoff,
    validate_normalized_handoff,
)
from gda_runner import resolve_gda, run_gda


def capabilities() -> dict[str, Any]:
    resolution = resolve_gda()
    return skill_envelope(
        command="capabilities",
        data={
            "skill": "gemini-design-agent",
            "version": PRODUCT_VERSION,
            "skill_protocol_version": SKILL_PROTOCOL_VERSION,
            "gemini_api_version": GEMINI_API_VERSION,
            "prompt_schema_version": PROMPT_SCHEMA_VERSION,
            "analysis_schema_version": ANALYSIS_SCHEMA_VERSION,
            "database_schema_version": DATABASE_SCHEMA_VERSION,
            "handoff_schema_version": HANDOFF_SCHEMA_VERSION,
            "gda_binary": resolution.path,
            "gda_binary_version": resolution.binary_version,
            "gda_binary_protocol_version": resolution.protocol_version,
            "gda_binary_source": resolution.source,
            "install_manifest_health": resolution.manifest_health,
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
            "supported_image_formats": ["image/png", "image/jpeg"],
            "gemini_interactions": {
                "api_version": "v1",
                "store": False,
            },
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
        diagnostics=[{
            "kind": "gda.compatibility",
            "message": warning,
        } for warning in resolution.warnings],
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
    account: str | None = None,
    fallback_models: list[str] | None = None,
    no_model_fallback: bool = False,
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
        account=account,
        fallback_models=fallback_models,
        no_model_fallback=no_model_fallback,
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
    account: str | None = None,
    fallback_models: list[str] | None = None,
    no_model_fallback: bool = False,
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
        "--timeout-seconds", str(timeout_seconds),
    ]

    if model:
        args.extend(["--model", model])
    if account:
        args.extend(["--account", account])
    for fallback_model in fallback_models or []:
        args.extend(["--fallback-model", fallback_model])
    if no_model_fallback:
        args.append("--no-model-fallback")
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
    account: str | None = None,
    fallback_models: list[str] | None = None,
    no_model_fallback: bool = False,
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
    if account:
        args.extend(["--account", account])
    for fallback_model in fallback_models or []:
        args.extend(["--fallback-model", fallback_model])
    if no_model_fallback:
        args.append("--no-model-fallback")

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


def runs_stats(
    project_dir: str = ".gda",
    since_days: int = 30,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    args = [
        "runs",
        "stats",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--since-days", str(since_days),
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


def lock_status(
    project_dir: str = ".gda",
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    return run_gda(
        ["lock", "status", "--project-dir", str(Path(project_dir).expanduser().resolve())],
        timeout_seconds=timeout_seconds,
    )


def lock_clear(
    project_dir: str = ".gda",
    force: bool = False,
    timeout_seconds: int = 60,
) -> dict[str, Any]:
    if not force:
        raise GDASkillError("lock clear requires --force")
    return run_gda(
        ["lock", "clear", "--project-dir", str(Path(project_dir).expanduser().resolve()), "--force"],
        timeout_seconds=timeout_seconds,
    )


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
                "credential_store_configured": None,
            },
            diagnostics=[{
                "kind": "auth",
                "status": "warn",
                "message": "GEMINI_API_KEY is set as a temporary override.",
                "resolution": "Run `gda auth onboard`; GDA will open Google sign-in in your browser.",
            }],
            next_actions=[{"label": "Sign in with Google", "command": "gda auth onboard"}],
        )

    status = auth_status(timeout_seconds=timeout_seconds)
    status_data = status.get("data") or {}
    configured = bool(status_data.get("configured"))
    if configured:
        return skill_envelope(
            command="auth.ensure",
            data={
                "usable": True,
                "source": "credential_store",
                "credential_store_configured": True,
                "method": status_data.get("method"),
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
