from __future__ import annotations

import argparse
from typing import Any

from gda_commands import (
    analyze,
    analyze_batch,
    analyze_handoff,
    auth_status,
    capabilities,
    compact,
    compare,
    doctor,
    ensure_auth,
    export,
    gc,
    init_project,
    lock_clear,
    lock_status,
    memory_conflicts,
    memory_explain,
    memory_export,
    memory_preview,
    memory_search,
    memory_show,
    runs_list,
    runs_recover,
    runs_show,
    runs_undo,
    setup,
    snapshot,
    validate_handoff,
)
from gda_constants import DEFAULT_ANALYSIS_REQUEST
from gda_envelope import GDASkillError


def build_parser() -> argparse.ArgumentParser:
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

    p_lock_status = sub.add_parser("lock-status")
    p_lock_status.add_argument("--project-dir", default=".gda")

    p_lock_clear = sub.add_parser("lock-clear")
    p_lock_clear.add_argument("--project-dir", default=".gda")
    p_lock_clear.add_argument("--force", action="store_true")

    sub.add_parser("auth-status")

    p_ensure_auth = sub.add_parser("ensure-auth")
    p_ensure_auth.add_argument("--no-open-terminal", action="store_true")
    p_ensure_auth.add_argument("--force", action="store_true")

    return parser


def dispatch(ns: argparse.Namespace) -> dict[str, Any]:
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
    elif ns.command == "lock-status":
        result = lock_status(project_dir=ns.project_dir)
    elif ns.command == "lock-clear":
        result = lock_clear(project_dir=ns.project_dir, force=ns.force)
    elif ns.command == "auth-status":
        result = auth_status()
    elif ns.command == "ensure-auth":
        result = ensure_auth(
            auto_open_terminal=not ns.no_open_terminal,
            force=ns.force,
        )
    else:
        raise GDASkillError(f"Unsupported command: {ns.command}")
    return result
