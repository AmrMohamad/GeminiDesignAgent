#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
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

    found = shutil.which("gda")
    if found:
        return found

    raise GDASkillError(
        "Could not find `gda`. Install GeminiDesignAgent or set GDA_BIN=/path/to/gda."
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


def analyze(
    image: str,
    screen: str,
    request: str,
    project_dir: str = ".gda",
    model: str | None = None,
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

    args = [
        "analyze",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--image", str(image_path),
        "--screen", screen,
        "--request", request,
    ]

    if model:
        args.extend(["--model", model])
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
    args = [
        "analyze",
        "--project-dir", str(Path(project_dir).expanduser().resolve()),
        "--batch-file", str(Path(batch_file).expanduser().resolve()),
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
    p_analyze.add_argument("--request", default=(
        "Extract layout, spacing, typography, colors, reusable components, "
        "and development-ready implementation values."
    ))
    p_analyze.add_argument("--project-dir", default=".gda")
    p_analyze.add_argument("--model", default=None)
    p_analyze.add_argument("--device-pixel-ratio", type=float, default=None)
    p_analyze.add_argument("--viewport", default=None)
    p_analyze.add_argument("--theme", default=None)
    p_analyze.add_argument("--state", default=None)
    p_analyze.add_argument("--locale-direction", default=None)
    p_analyze.add_argument("--timeout-seconds", type=int, default=180)

    p_batch = sub.add_parser("analyze-batch")
    p_batch.add_argument("--batch-file", required=True)
    p_batch.add_argument("--project-dir", default=".gda")
    p_batch.add_argument("--request", default=(
        "Extract layout, spacing, typography, colors, reusable components, "
        "and development-ready implementation values."
    ))
    p_batch.add_argument("--preset", default=None)
    p_batch.add_argument("--timeout-seconds", type=int, default=600)

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
                device_pixel_ratio=ns.device_pixel_ratio,
                viewport=ns.viewport,
                theme=ns.theme,
                state=ns.state,
                locale_direction=ns.locale_direction,
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
