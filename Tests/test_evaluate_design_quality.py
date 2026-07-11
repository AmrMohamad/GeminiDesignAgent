from __future__ import annotations

import copy
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "evaluate_design_quality.py"
SPEC = importlib.util.spec_from_file_location("evaluate_design_quality", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
evaluation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evaluation)


class DesignQualityEvaluationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.public_corpus = REPO_ROOT / "evals" / "design-quality" / "public"
        cls.fixture_dir = cls.public_corpus / "login-card-light"
        cls.manifest = json.loads((cls.fixture_dir / "manifest.json").read_text(encoding="utf-8"))
        cls.analysis = json.loads((cls.fixture_dir / "recorded-analysis.json").read_text(encoding="utf-8"))

    def test_perfect_analysis_scores_one(self) -> None:
        result = evaluation.score_fixture(self.manifest, self.analysis)
        self.assertTrue(result["passed"])
        self.assertEqual(result["score"], 1.0)
        self.assertEqual(result["missing_required"], [])

    def test_tolerant_analysis_accepts_small_visual_differences(self) -> None:
        analysis = copy.deepcopy(self.analysis)
        for element in analysis["elements"]:
            element["bboxPx"]["x"] += 3
            element["bboxPx"]["y"] += 2
            element["label"] = f"{element['label']}!"
        analysis["tokens"]["colors"][2]["hex"] = "#356AE0"
        for token in analysis["tokens"]["typography"]:
            token["fontSizePx"] += 2

        result = evaluation.score_fixture(self.manifest, analysis)
        self.assertTrue(result["passed"])
        self.assertGreaterEqual(result["score"], 0.95)

    def test_low_quality_analysis_fails_without_schema_failure(self) -> None:
        analysis = copy.deepcopy(self.analysis)
        for element in analysis["elements"]:
            element["bboxPx"]["x"] += 300
        analysis["tokens"]["colors"] = []
        analysis["tokens"]["typography"] = [
            {"name": item["name"], "fontSizePx": 100, "fontWeight": "100"}
            for item in self.manifest["expected"]["typography"]
        ]
        analysis["components"] = []

        result = evaluation.score_fixture(self.manifest, analysis)
        self.assertFalse(result["passed"])
        self.assertLess(result["score"], self.manifest["minimum_score"])
        self.assertEqual(result["dimensions"]["required_element_recall"], 1.0)

    def test_malformed_analysis_is_rejected(self) -> None:
        with self.assertRaises(evaluation.EvaluationError):
            evaluation.score_fixture(self.manifest, {"schemaVersion": "1.0", "elements": []})

    def test_missing_hard_required_element_is_a_hard_failure(self) -> None:
        analysis = copy.deepcopy(self.analysis)
        analysis["elements"] = [item for item in analysis["elements"] if item["id"] != "login-card"]

        result = evaluation.score_fixture(self.manifest, analysis)
        self.assertFalse(result["passed"])
        self.assertEqual(result["missing_hard_required"], ["Authentication Card"])

    def test_recorded_public_corpus_passes_release_thresholds(self) -> None:
        report = evaluation.evaluate_corpus(self.public_corpus, "recorded")
        self.assertTrue(report["passed"])
        self.assertEqual(report["fixture_count"], 4)
        self.assertGreaterEqual(report["mean_score"], 0.80)

    def test_sequential_recorded_mode_reports_memory_safety_invariants(self) -> None:
        report = evaluation.evaluate_sequential_corpus(self.public_corpus, "recorded")
        self.assertTrue(report["passed"])
        self.assertEqual(report["metrics"]["unsafe_global_memory_count"], 0)
        self.assertEqual(report["metrics"]["unresolved_element_reference_count"], 0)
        self.assertEqual(report["metrics"]["invalid_final_measurement_count"], 0)
        self.assertEqual(report["metrics"]["memory_recall_coverage"], 1.0)
        self.assertEqual(report["metrics"]["component_name_reuse"], 1.0)
        self.assertEqual(report["metrics"]["design_token_consistency"], 1.0)
        self.assertIn("major_element_coordinate_mae_px", report["metrics"])

    def test_public_corpus_covers_sequential_product_variants_and_injection_text(self) -> None:
        manifests = [json.loads(path.read_text(encoding="utf-8")) for path in self.public_corpus.glob("*/manifest.json")]
        auth = [item for item in manifests if item.get("group") == "orbit-auth"]
        self.assertGreaterEqual(len(auth), 2)
        self.assertEqual({item.get("theme") for item in auth}, {"light", "dark"})
        self.assertEqual({item.get("viewport") for item in auth}, {"desktop", "mobile"})
        self.assertEqual({item.get("locale_direction") for item in auth}, {"ltr", "rtl"})
        self.assertTrue(any(item.get("contains_prompt_injection_text") is True for item in auth))
        self.assertTrue(any(item.get("recall_signals") for item in auth))

    def test_private_corpus_uses_same_schema_without_leaking_path(self) -> None:
        with tempfile.TemporaryDirectory(prefix="private-design-corpus-") as temporary:
            private = Path(temporary) / "private"
            destination = private / "owned-login"
            shutil.copytree(self.fixture_dir, destination)
            manifest_path = destination / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["id"] = "owned-login"
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

            report = evaluation.evaluate_corpus(private, "recorded")
            serialized = json.dumps(report)
            self.assertTrue(report["passed"])
            self.assertNotIn(temporary, serialized)
            self.assertNotIn("fixture.png", serialized)

    def test_fixture_checksum_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="drifted-design-corpus-") as temporary:
            corpus = Path(temporary)
            destination = corpus / "drifted"
            shutil.copytree(self.fixture_dir, destination)
            (destination / "fixture.png").write_bytes(b"not the fixture")

            with self.assertRaises(evaluation.EvaluationError):
                evaluation.evaluate_corpus(corpus, "recorded")


if __name__ == "__main__":
    unittest.main()
