from __future__ import annotations

import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "smoke_installed_skill.py"
SPEC = importlib.util.spec_from_file_location("smoke_installed_skill", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
smoke = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(smoke)


class InstalledSkillSmokeContractTests(unittest.TestCase):
    def test_top_level_analyze_telemetry_is_accepted(self) -> None:
        locations = smoke.telemetry_locations(
            {"usage": {"input_tokens": 1}, "metrics": {"duration_ms": 2}},
            {},
        )
        self.assertEqual(locations["usage"], "analyze.data.usage")
        self.assertEqual(locations["metrics"], "analyze.data.metrics")

    def test_persisted_camel_case_run_telemetry_is_accepted(self) -> None:
        locations = smoke.telemetry_locations(
            {},
            {"inputTokens": 1, "durationMs": 2, "gdaVersion": "0.1.0"},
        )
        self.assertEqual(locations["usage"], "runs-show.data.run")
        self.assertEqual(locations["metrics"], "runs-show.data.run")

    def test_missing_telemetry_is_rejected(self) -> None:
        with self.assertRaises(smoke.SmokeFailure) as context:
            smoke.telemetry_locations({}, {})
        self.assertEqual(context.exception.code, "TELEMETRY_MISSING")

    def test_doctor_requires_ready_and_named_proof_layers(self) -> None:
        checks = [
            {"name": name, "status": "pass"}
            for name in ("model", "auth", "project.exists", "database.integrity", "memory.stats")
        ]
        smoke.assert_doctor({"data": {"ready": True, "checks": checks}})
        with self.assertRaises(smoke.SmokeFailure):
            smoke.assert_doctor({"data": {"ready": False, "checks": checks}})

    def test_run_requires_completed_status_and_artifacts(self) -> None:
        run, artifacts = smoke.assert_run(
            {
                "data": {
                    "run": {"id": "run_1", "status": "completed"},
                    "artifacts": {"analysis_exists": True, "prompt_exists": False},
                }
            },
            "run_1",
        )
        self.assertEqual(run["id"], "run_1")
        self.assertTrue(artifacts["analysis_exists"])

    def test_lock_reports_require_both_locks_absent(self) -> None:
        smoke.assert_locks(
            {"data": {"locks": [{"kind": "project", "present": False}, {"kind": "records", "present": False}]}}
        )
        with self.assertRaises(smoke.SmokeFailure):
            smoke.assert_locks(
                {"data": {"locks": [{"kind": "project", "present": True}, {"kind": "records", "present": False}]}}
            )

    def test_database_integrity_and_evidence_are_checked_read_only(self) -> None:
        with tempfile.TemporaryDirectory(prefix="smoke-database-") as temporary:
            project = Path(temporary)
            connection = sqlite3.connect(project / "memory.db")
            connection.execute("CREATE TABLE evidence_records (run_id TEXT NOT NULL)")
            connection.executemany("INSERT INTO evidence_records VALUES (?)", [("run_1",), ("run_2",)])
            connection.commit()
            connection.close()

            smoke.assert_database(project, ["run_1", "run_2"])

    def test_run_stats_require_two_completed_runs_and_aggregates(self) -> None:
        smoke.assert_run_stats(
            {
                "ok": True,
                "command": "runs.stats",
                "schema_version": "1.0",
                "data": {
                    "total_runs": 2,
                    "completed_runs": 2,
                    "failed_runs": 0,
                    "unpriced_runs": 0,
                    "input_tokens": 120,
                    "output_tokens": 80,
                    "thought_tokens": 20,
                    "total_tokens": 220,
                    "average_duration_ms": 1500.0,
                    "p95_duration_ms": 1700,
                    "upper_bound_estimated_cost_usd": 0.001,
                    "by_model": [{"value": "gemini-3.5-flash", "run_count": 2}],
                    "by_status": [{"value": "completed", "run_count": 2}],
                },
            }
        )

    def test_run_stats_reject_count_mismatch(self) -> None:
        payload = {
            "ok": True,
            "command": "runs.stats",
            "schema_version": "1.0",
            "data": {
                "total_runs": 2,
                "completed_runs": 1,
                "failed_runs": 1,
            },
        }
        with self.assertRaises(smoke.SmokeFailure) as context:
            smoke.assert_run_stats(payload)
        self.assertEqual(context.exception.code, "RUN_STATS_COUNTS_MISMATCH")

    def test_run_stats_reject_missing_telemetry_or_cost_aggregates(self) -> None:
        payload = {
            "ok": True,
            "command": "runs.stats",
            "schema_version": "1.0",
            "data": {
                "total_runs": 2,
                "completed_runs": 2,
                "failed_runs": 0,
                "unpriced_runs": 0,
                "input_tokens": 10,
                "output_tokens": 10,
                "thought_tokens": 0,
                "total_tokens": 20,
                "average_duration_ms": 1000.0,
                "p95_duration_ms": 1000,
                "by_model": [],
                "by_status": [],
            },
        }
        with self.assertRaises(smoke.SmokeFailure) as context:
            smoke.assert_run_stats(payload)
        self.assertEqual(context.exception.code, "RUN_STATS_AGGREGATES_MISSING")


if __name__ == "__main__":
    unittest.main()
