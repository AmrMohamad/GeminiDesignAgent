#!/usr/bin/env python3
"""Live installed-skill adoption smoke with safe temporary state.

The smoke never prints credentials, subprocess stderr, raw Gemini responses,
prompts, or filesystem paths. It can use GEMINI_API_KEY in trusted CI or the
platform credential store locally. Interactive onboarding is always disabled.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


class SmokeFailure(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def run_wrapper(
    skill_dir: Path,
    args: Iterable[str],
    timeout_seconds: int,
) -> dict[str, Any]:
    wrapper = skill_dir / "gda_skill.py"
    if not wrapper.is_file():
        raise SmokeFailure("SKILL_WRAPPER_MISSING", "The installed skill wrapper is missing.")
    environment = os.environ.copy()
    environment["GDA_DISABLE_AUTH_ONBOARDING"] = "1"
    try:
        process = subprocess.run(
            [sys.executable, str(wrapper), *args],
            cwd=str(skill_dir),
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_seconds,
            shell=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise SmokeFailure("SMOKE_COMMAND_TIMEOUT", "An installed-skill command timed out.") from exc
    try:
        payload = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise SmokeFailure("SMOKE_INVALID_JSON", "The installed skill returned invalid JSON.") from exc
    if not isinstance(payload, dict):
        raise SmokeFailure("SMOKE_INVALID_JSON", "The installed skill JSON was not an object.")
    if process.returncode != 0 or payload.get("ok") is not True:
        error = payload.get("error")
        code = error.get("code") if isinstance(error, dict) else "SMOKE_COMMAND_FAILED"
        if code in {
            "AUTH_ONBOARDING_UNAVAILABLE",
            "AUTH_ONBOARDING_INTERACTIVE_REQUIRED",
            "API_KEY_MISSING",
        }:
            raise SmokeFailure(
                "AUTH_ONBOARDING_UNAVAILABLE",
                "Gemini authentication is unavailable in this non-interactive smoke.",
            )
        raise SmokeFailure(str(code), "An installed-skill command failed.")
    return payload


def require_mapping(value: object, code: str, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SmokeFailure(code, f"{label} is missing or malformed.")
    return value


def require_list(value: object, code: str, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise SmokeFailure(code, f"{label} is missing or malformed.")
    return value


def analyze_data(payload: dict[str, Any]) -> dict[str, Any]:
    return require_mapping(payload.get("data"), "ANALYZE_DATA_MISSING", "Analyze data")


def telemetry_locations(
    analyze: dict[str, Any],
    run: dict[str, Any],
) -> dict[str, str]:
    """Accept the planned top-level telemetry or the persisted run equivalent.

    Planned paths are analyze data.usage and data.metrics. A migrated RunRecord
    can prove the same contract with duration/version/usage fields in runs-show.
    Presence is checked independently of nullability so API-omitted usage remains
    valid while the versioned telemetry schema is still proven.
    """
    usage = analyze.get("usage")
    metrics = analyze.get("metrics")
    run_usage_keys = {"inputTokens", "input_tokens", "usageJSON", "usage_json"}
    run_metric_keys = {"durationMs", "duration_ms", "gdaVersion", "gda_version"}
    usage_location = "analyze.data.usage" if isinstance(usage, dict) else None
    metrics_location = "analyze.data.metrics" if isinstance(metrics, dict) else None
    if usage_location is None and run_usage_keys.intersection(run):
        usage_location = "runs-show.data.run"
    if metrics_location is None and run_metric_keys.intersection(run):
        metrics_location = "runs-show.data.run"
    if usage_location is None or metrics_location is None:
        raise SmokeFailure(
            "TELEMETRY_MISSING",
            "Analyze usage/metrics and persisted run telemetry are missing.",
        )
    return {"usage": usage_location, "metrics": metrics_location}


def assert_doctor(payload: dict[str, Any]) -> None:
    data = require_mapping(payload.get("data"), "DOCTOR_DATA_MISSING", "Doctor data")
    if data.get("ready") is not True:
        raise SmokeFailure("DOCTOR_NOT_READY", "gda doctor did not report ready.")
    checks = require_list(data.get("checks"), "DOCTOR_CHECKS_MISSING", "Doctor checks")
    if any(isinstance(check, dict) and check.get("status") == "fail" for check in checks):
        raise SmokeFailure("DOCTOR_CHECK_FAILED", "gda doctor contains a failed check.")
    names = {check.get("name") for check in checks if isinstance(check, dict)}
    required = {"model", "auth", "project.exists", "database.integrity", "memory.stats"}
    if not required.issubset(names):
        raise SmokeFailure("DOCTOR_CHECKS_INCOMPLETE", "gda doctor omitted required adoption checks.")


def assert_run(payload: dict[str, Any], expected_run_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    data = require_mapping(payload.get("data"), "RUN_DATA_MISSING", "Run data")
    run = require_mapping(data.get("run"), "RUN_RECORD_MISSING", "Run record")
    artifacts = require_mapping(data.get("artifacts"), "RUN_ARTIFACTS_MISSING", "Run artifacts")
    if run.get("id") != expected_run_id or run.get("status") != "completed":
        raise SmokeFailure("RUN_NOT_COMPLETED", "The inspected run is not completed.")
    if artifacts.get("analysis_exists") is not True:
        raise SmokeFailure("RUN_ARTIFACT_MISSING", "The completed run is missing its analysis artifact.")
    return run, artifacts


def assert_database(project_dir: Path, run_ids: list[str]) -> None:
    database = project_dir / "memory.db"
    if not database.is_file():
        raise SmokeFailure("DATABASE_MISSING", "The smoke project database is missing.")
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()
        if integrity is None or integrity[0] != "ok":
            raise SmokeFailure("DATABASE_INTEGRITY_FAILED", "SQLite integrity_check did not return ok.")
        placeholders = ",".join("?" for _ in run_ids)
        count = connection.execute(
            f"SELECT COUNT(*) FROM evidence_records WHERE run_id IN ({placeholders})",
            run_ids,
        ).fetchone()
        if count is None or int(count[0]) < len(run_ids):
            raise SmokeFailure("EVIDENCE_MISSING", "One or more completed runs have no evidence record.")
    finally:
        connection.close()


def assert_locks(payload: dict[str, Any]) -> None:
    data = require_mapping(payload.get("data"), "LOCK_DATA_MISSING", "Lock data")
    locks = require_list(data.get("locks"), "LOCK_REPORT_MISSING", "Lock reports")
    if len(locks) < 2:
        raise SmokeFailure("LOCK_REPORT_INCOMPLETE", "Project and records lock reports are required.")
    if any(isinstance(lock, dict) and lock.get("present") is not False for lock in locks):
        raise SmokeFailure("LOCK_LEFT_BEHIND", "A project or records lock remains after analysis.")


def assert_run_stats(payload: dict[str, Any]) -> None:
    if payload.get("ok") is not True or payload.get("command") != "runs.stats":
        raise SmokeFailure("RUN_STATS_ENVELOPE_INVALID", "runs-stats returned an invalid envelope.")
    if not isinstance(payload.get("schema_version"), str):
        raise SmokeFailure("RUN_STATS_ENVELOPE_INVALID", "runs-stats omitted its schema version.")
    data = require_mapping(payload.get("data"), "RUN_STATS_DATA_MISSING", "Run statistics")
    counts = {
        "total_runs": data.get("total_runs"),
        "completed_runs": data.get("completed_runs"),
        "failed_runs": data.get("failed_runs"),
    }
    if any(not isinstance(value, int) or isinstance(value, bool) for value in counts.values()):
        raise SmokeFailure("RUN_STATS_COUNTS_INVALID", "Run statistics counts are missing or malformed.")
    if counts["total_runs"] < 2 or counts["completed_runs"] < 2 or counts["failed_runs"] != 0:
        raise SmokeFailure("RUN_STATS_COUNTS_MISMATCH", "Run statistics do not agree with the two-pass smoke.")
    aggregate_fields = {
        "unpriced_runs",
        "input_tokens",
        "output_tokens",
        "thought_tokens",
        "total_tokens",
        "average_duration_ms",
        "p95_duration_ms",
        "upper_bound_estimated_cost_usd",
        "by_model",
        "by_status",
    }
    if not aggregate_fields.issubset(data):
        raise SmokeFailure(
            "RUN_STATS_AGGREGATES_MISSING",
            "Run statistics omitted telemetry or cost aggregation fields.",
        )
    numeric_fields = aggregate_fields - {"by_model", "by_status"}
    if any(
        not isinstance(data[field], (int, float)) or isinstance(data[field], bool)
        for field in numeric_fields
    ):
        raise SmokeFailure(
            "RUN_STATS_AGGREGATES_INVALID",
            "Run statistics telemetry or cost aggregates are malformed.",
        )
    if not isinstance(data["by_model"], list) or not isinstance(data["by_status"], list):
        raise SmokeFailure("RUN_STATS_AGGREGATES_INVALID", "Run statistics groups are malformed.")


def run_smoke(skill_dir: Path, image: Path, timeout_seconds: int) -> dict[str, Any]:
    if not skill_dir.is_dir():
        raise SmokeFailure("SKILL_DIR_MISSING", "The installed skill directory does not exist.")
    if not image.is_file():
        raise SmokeFailure("SMOKE_IMAGE_MISSING", "The synthetic smoke image is missing.")

    with tempfile.TemporaryDirectory(prefix="gda-adoption-smoke-") as temporary:
        project_dir = Path(temporary) / "project.gda"
        run_wrapper(skill_dir, ["ensure-auth", "--no-open-terminal"], timeout_seconds)
        run_wrapper(
            skill_dir,
            ["setup", "--project-dir", str(project_dir), "--project-name", "GDA Adoption Smoke"],
            timeout_seconds,
        )
        doctor = run_wrapper(
            skill_dir,
            ["doctor", "--project-dir", str(project_dir), "--image", str(image)],
            timeout_seconds,
        )
        assert_doctor(doctor)

        first_payload = run_wrapper(
            skill_dir,
            [
                "analyze",
                "--image", str(image),
                "--screen", "Login Adoption Smoke",
                "--request", "Extract reusable login layout, tokens, components, and write durable design memory.",
                "--project-dir", str(project_dir),
                "--theme", "light",
                "--locale-direction", "ltr",
                "--timeout-seconds", str(timeout_seconds),
            ],
            timeout_seconds + 30,
        )
        first = analyze_data(first_payload)
        first_run_id = first.get("runId")
        first_memory = require_mapping(first.get("memory"), "MEMORY_DATA_MISSING", "First-run memory")
        written = require_list(first_memory.get("writtenAtomIds"), "MEMORY_WRITE_MISSING", "First-run written atom IDs")
        if not isinstance(first_run_id, str) or not first_run_id or not written:
            raise SmokeFailure("MEMORY_WRITE_MISSING", "The first analysis did not produce a run and memory writes.")

        second_payload = run_wrapper(
            skill_dir,
            [
                "analyze",
                "--image", str(image),
                "--screen", "Login Adoption Smoke",
                "--request", "Reuse the existing login design memory and verify the same tokens and components.",
                "--project-dir", str(project_dir),
                "--theme", "light",
                "--locale-direction", "ltr",
                "--timeout-seconds", str(timeout_seconds),
            ],
            timeout_seconds + 30,
        )
        second = analyze_data(second_payload)
        second_run_id = second.get("runId")
        second_memory = require_mapping(second.get("memory"), "MEMORY_DATA_MISSING", "Second-run memory")
        used = require_list(second_memory.get("usedAtomIds"), "MEMORY_RECALL_MISSING", "Second-run used atom IDs")
        if not isinstance(second_run_id, str) or not second_run_id:
            raise SmokeFailure("SECOND_RUN_MISSING", "The second analysis did not produce a run ID.")
        recalled = sorted(set(str(value) for value in written).intersection(str(value) for value in used))
        if not recalled:
            raise SmokeFailure(
                "MEMORY_RECALL_MISSING",
                "Second-run used atom IDs do not intersect first-run written atom IDs.",
            )

        first_run, _ = assert_run(
            run_wrapper(
                skill_dir,
                ["runs-show", "--project-dir", str(project_dir), "--id", first_run_id],
                timeout_seconds,
            ),
            first_run_id,
        )
        second_run, _ = assert_run(
            run_wrapper(
                skill_dir,
                ["runs-show", "--project-dir", str(project_dir), "--id", second_run_id],
                timeout_seconds,
            ),
            second_run_id,
        )
        first_telemetry = telemetry_locations(first, first_run)
        second_telemetry = telemetry_locations(second, second_run)
        assert_database(project_dir, [first_run_id, second_run_id])
        assert_run_stats(
            run_wrapper(
                skill_dir,
                ["runs-stats", "--project-dir", str(project_dir), "--since-days", "30"],
                timeout_seconds,
            )
        )
        assert_locks(
            run_wrapper(
                skill_dir,
                ["lock-status", "--project-dir", str(project_dir)],
                timeout_seconds,
            )
        )

        return {
            "ok": True,
            "schema_version": "1.0",
            "checks": {
                "auth_ready": True,
                "doctor_ready": True,
                "first_run_completed": True,
                "second_run_completed": True,
                "evidence_present": True,
                "sqlite_integrity": "ok",
                "locks_absent": True,
                "runs_stats_verified": True,
                "memory_recall_intersection_count": len(recalled),
                "telemetry": {"first": first_telemetry, "second": second_telemetry},
                "temporary_project_cleaned_on_exit": True,
            },
        }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a live two-pass installed-skill adoption smoke.")
    parser.add_argument("--skill-dir", required=True, help="Installed gemini-design-agent skill directory")
    parser.add_argument("--image", default=None, help="Optional PNG/JPEG smoke input")
    parser.add_argument("--timeout-seconds", type=int, default=180)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo_root = Path(__file__).resolve().parents[1]
    image = (
        Path(args.image).expanduser().resolve()
        if args.image
        else repo_root / "evals" / "design-quality" / "public" / "login-card-light" / "fixture.png"
    )
    try:
        report = run_smoke(Path(args.skill_dir).expanduser().resolve(), image, args.timeout_seconds)
    except SmokeFailure as exc:
        report = {
            "ok": False,
            "schema_version": "1.0",
            "error": {"code": exc.code, "message": str(exc)},
        }
    print(json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False))
    return 0 if report.get("ok") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
