#!/usr/bin/env python3
"""Deterministic quality scoring for GeminiDesignAgent design analyses.

Recorded mode scores checked-in DesignAnalysis fixtures without network access.
Live mode invokes an installed gemini-design-agent skill in a fresh project per
fixture. Reports contain scores and labels only; image paths, prompts, raw model
output, credentials, and subprocess output are intentionally excluded.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


WEIGHTS = {
    "required_element_recall": 0.35,
    "bounding_box_iou": 0.25,
    "color_matching": 0.15,
    "typography_matching": 0.15,
    "component_token_recognition": 0.10,
}
DEFAULT_FIXTURE_MINIMUM = 0.70
DEFAULT_CORPUS_MINIMUM = 0.80
TEXT_MATCH_MINIMUM = 0.50
COLOR_DISTANCE_MAXIMUM = 24.0
TYPOGRAPHY_SIZE_TOLERANCE = 2


class EvaluationError(RuntimeError):
    """A manifest, analysis, live invocation, or corpus contract failed."""


def normalize_text(value: object) -> str:
    text = str(value or "").casefold()
    text = re.sub(r"[^\w\s]", "", text, flags=re.UNICODE)
    return " ".join(text.split())


def text_similarity(left: object, right: object) -> float:
    a, b = normalize_text(left), normalize_text(right)
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def _number(value: object, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise EvaluationError(f"{label} must be numeric")
    return float(value)


def validate_bbox(value: object, label: str) -> dict[str, float]:
    if not isinstance(value, dict):
        raise EvaluationError(f"{label} must be an object")
    required = ("x", "y", "width", "height")
    if not all(key in value for key in required):
        raise EvaluationError(f"{label} must contain x, y, width, and height")
    box = {key: _number(value[key], f"{label}.{key}") for key in required}
    if box["width"] <= 0 or box["height"] <= 0:
        raise EvaluationError(f"{label} width and height must be positive")
    return box


def intersection_over_union(left: dict[str, float], right: dict[str, float]) -> float:
    left_x2, left_y2 = left["x"] + left["width"], left["y"] + left["height"]
    right_x2, right_y2 = right["x"] + right["width"], right["y"] + right["height"]
    width = max(0.0, min(left_x2, right_x2) - max(left["x"], right["x"]))
    height = max(0.0, min(left_y2, right_y2) - max(left["y"], right["y"]))
    intersection = width * height
    union = left["width"] * left["height"] + right["width"] * right["height"] - intersection
    return intersection / union if union > 0 else 0.0


def iou_credit(iou: float) -> float:
    """Full credit at .70, linearly declining to zero at .40."""
    if iou >= 0.70:
        return 1.0
    if iou < 0.40:
        return 0.0
    return (iou - 0.40) / 0.30


def normalize_hex(value: object) -> tuple[int, int, int] | None:
    if not isinstance(value, str):
        return None
    text = value.strip().lstrip("#")
    if len(text) == 3:
        text = "".join(character * 2 for character in text)
    if len(text) == 8:
        text = text[:6]
    if len(text) != 6 or re.fullmatch(r"[0-9a-fA-F]{6}", text) is None:
        return None
    return tuple(int(text[index : index + 2], 16) for index in (0, 2, 4))


def color_distance(left: object, right: object) -> float:
    a, b = normalize_hex(left), normalize_hex(right)
    if a is None or b is None:
        return math.inf
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def _require_list(value: object, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise EvaluationError(f"{label} must be an array")
    return value


def validate_manifest(manifest: object, source_name: str = "manifest") -> dict[str, Any]:
    if not isinstance(manifest, dict):
        raise EvaluationError(f"{source_name} must be an object")
    for key in ("schema_version", "id", "image", "image_sha256", "source", "screen", "request", "canvas", "expected"):
        if key not in manifest:
            raise EvaluationError(f"{source_name} is missing {key}")
    if manifest["schema_version"] != "1.0":
        raise EvaluationError(f"{source_name} uses unsupported schema_version")
    if not isinstance(manifest["id"], str) or not manifest["id"].strip():
        raise EvaluationError(f"{source_name}.id must be a non-empty string")
    for key in ("image", "source", "screen", "request"):
        if not isinstance(manifest[key], str) or not manifest[key].strip():
            raise EvaluationError(f"{source_name}.{key} must be a non-empty string")
    if not isinstance(manifest["image_sha256"], str) or re.fullmatch(r"[0-9a-fA-F]{64}", manifest["image_sha256"]) is None:
        raise EvaluationError(f"{source_name}.image_sha256 must be a SHA-256 hex digest")
    canvas = manifest["canvas"]
    if not isinstance(canvas, dict):
        raise EvaluationError(f"{source_name}.canvas must be an object")
    width = _number(canvas.get("width"), f"{source_name}.canvas.width")
    height = _number(canvas.get("height"), f"{source_name}.canvas.height")
    if width <= 0 or height <= 0:
        raise EvaluationError(f"{source_name}.canvas dimensions must be positive")
    expected = manifest["expected"]
    if not isinstance(expected, dict):
        raise EvaluationError(f"{source_name}.expected must be an object")
    elements = _require_list(expected.get("required_elements"), f"{source_name}.expected.required_elements")
    for index, element in enumerate(elements):
        label = f"{source_name}.expected.required_elements[{index}]"
        if not isinstance(element, dict):
            raise EvaluationError(f"{label} must be an object")
        if not isinstance(element.get("type"), str) or not element["type"]:
            raise EvaluationError(f"{label}.type must be a non-empty string")
        if not isinstance(element.get("label"), str):
            raise EvaluationError(f"{label}.label must be a string")
        validate_bbox(element.get("bbox_px"), f"{label}.bbox_px")
        if not isinstance(element.get("hard_required"), bool):
            raise EvaluationError(f"{label}.hard_required must be boolean")
    for key in ("colors", "typography", "components"):
        _require_list(expected.get(key), f"{source_name}.expected.{key}")
    minimum = manifest.get("minimum_score", DEFAULT_FIXTURE_MINIMUM)
    if not isinstance(minimum, (int, float)) or not 0 <= float(minimum) <= 1:
        raise EvaluationError(f"{source_name}.minimum_score must be between 0 and 1")
    return manifest


def validate_fixture_files(fixture_dir: Path, manifest: dict[str, Any]) -> None:
    image = fixture_dir / manifest["image"]
    source = fixture_dir / manifest["source"]
    if not image.is_file() or not source.is_file():
        raise EvaluationError(f"{manifest['id']}: fixture image or source is missing")
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    expected = manifest["image_sha256"]
    if not isinstance(expected, str) or digest.casefold() != expected.casefold():
        raise EvaluationError(f"{manifest['id']}: fixture image checksum mismatch")


def validate_analysis(analysis: object, fixture_id: str = "analysis") -> dict[str, Any]:
    if not isinstance(analysis, dict):
        raise EvaluationError(f"{fixture_id}: DesignAnalysis must be an object")
    if not isinstance(analysis.get("schemaVersion"), str):
        raise EvaluationError(f"{fixture_id}: DesignAnalysis.schemaVersion must be a string")
    _require_list(analysis.get("elements"), f"{fixture_id}: DesignAnalysis.elements")
    _require_list(analysis.get("components"), f"{fixture_id}: DesignAnalysis.components")
    if not isinstance(analysis.get("tokens"), dict):
        raise EvaluationError(f"{fixture_id}: DesignAnalysis.tokens must be an object")
    return analysis


def unwrap_analysis(payload: object, fixture_id: str) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise EvaluationError(f"{fixture_id}: analysis payload must be an object")
    candidate: object = payload
    if isinstance(payload.get("data"), dict):
        candidate = payload["data"]
    if isinstance(candidate, dict) and isinstance(candidate.get("analysis"), dict):
        candidate = candidate["analysis"]
    return validate_analysis(candidate, fixture_id)


def element_bbox(element: dict[str, Any], width: float, height: float) -> dict[str, float] | None:
    if isinstance(element.get("bboxPx"), dict):
        try:
            return validate_bbox(element["bboxPx"], "element.bboxPx")
        except EvaluationError:
            return None
    normalized = element.get("bbox1000")
    if not isinstance(normalized, dict):
        return None
    keys = ("xmin", "ymin", "xmax", "ymax")
    if not all(isinstance(normalized.get(key), (int, float)) for key in keys):
        return None
    x1 = float(normalized["xmin"]) / 1000.0 * width
    y1 = float(normalized["ymin"]) / 1000.0 * height
    x2 = float(normalized["xmax"]) / 1000.0 * width
    y2 = float(normalized["ymax"]) / 1000.0 * height
    if x2 <= x1 or y2 <= y1:
        return None
    return {"x": x1, "y": y1, "width": x2 - x1, "height": y2 - y1}


def element_label(element: dict[str, Any]) -> str:
    return str(element.get("label") or element.get("visibleText") or "")


def match_elements(
    expected: list[dict[str, Any]],
    predicted: list[Any],
    width: float,
    height: float,
) -> tuple[list[dict[str, Any]], list[str]]:
    candidates = [item for item in predicted if isinstance(item, dict)]
    used: set[int] = set()
    matches: list[dict[str, Any]] = []
    missing: list[str] = []
    for wanted in expected:
        wanted_box = validate_bbox(wanted["bbox_px"], "expected bbox")
        best: tuple[float, int, float, float, dict[str, float]] | None = None
        for index, candidate in enumerate(candidates):
            if index in used or normalize_text(candidate.get("type")) != normalize_text(wanted["type"]):
                continue
            similarity = text_similarity(wanted["label"], element_label(candidate))
            if wanted["label"] and similarity < TEXT_MATCH_MINIMUM:
                continue
            candidate_box = element_bbox(candidate, width, height)
            iou = intersection_over_union(wanted_box, candidate_box) if candidate_box else 0.0
            rank = similarity * 0.40 + iou * 0.60
            if candidate_box is not None and (best is None or rank > best[0]):
                best = (rank, index, similarity, iou, candidate_box)
        if best is None:
            missing.append(wanted["label"] or wanted["type"])
            continue
        used.add(best[1])
        matches.append({
            "label": wanted["label"] or wanted["type"],
            "type": wanted["type"],
            "hard_required": wanted["hard_required"],
            "text_similarity": best[2],
            "iou": best[3],
            "coordinate_mae_px": sum(
                abs(wanted_box[key] - best[4][key])
                for key in ("x", "y", "width", "height")
            ) / 4.0,
        })
    return matches, missing


def predicted_colors(analysis: dict[str, Any]) -> list[str]:
    values: list[str] = []
    tokens = analysis.get("tokens") or {}
    for token in tokens.get("colors") or []:
        if isinstance(token, dict) and isinstance(token.get("hex"), str):
            values.append(token["hex"])
    for element in analysis.get("elements") or []:
        if not isinstance(element, dict):
            continue
        values.extend(value for value in element.get("colorsHex") or [] if isinstance(value, str))
        typography = element.get("typography")
        if isinstance(typography, dict) and isinstance(typography.get("colorHex"), str):
            values.append(typography["colorHex"])
    return values


def score_colors(expected: list[Any], predicted: list[str]) -> float:
    if not expected:
        return 1.0
    remaining = list(predicted)
    matched = 0
    for item in expected:
        wanted = item.get("hex") if isinstance(item, dict) else item
        distances = [(color_distance(wanted, value), index) for index, value in enumerate(remaining)]
        distances = [entry for entry in distances if entry[0] <= COLOR_DISTANCE_MAXIMUM]
        if distances:
            _, index = min(distances)
            remaining.pop(index)
            matched += 1
    return matched / len(expected)


def predicted_typography(analysis: dict[str, Any]) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    for token in (analysis.get("tokens") or {}).get("typography") or []:
        if isinstance(token, dict):
            values.append(token)
    for element in analysis.get("elements") or []:
        if not isinstance(element, dict) or not isinstance(element.get("typography"), dict):
            continue
        typography = dict(element["typography"])
        typography.setdefault("name", element_label(element))
        values.append(typography)
    return values


def score_typography(expected: list[Any], predicted: list[dict[str, Any]]) -> float:
    if not expected:
        return 1.0
    remaining = list(predicted)
    total = 0.0
    for wanted in expected:
        if not isinstance(wanted, dict):
            continue
        ranked: list[tuple[float, int]] = []
        for index, candidate in enumerate(remaining):
            similarity = text_similarity(wanted.get("name"), candidate.get("name"))
            if wanted.get("name") and similarity < TEXT_MATCH_MINIMUM:
                continue
            size = candidate.get("fontSizePx")
            size_ok = isinstance(size, (int, float)) and abs(float(size) - float(wanted["font_size_px"])) <= TYPOGRAPHY_SIZE_TOLERANCE
            wanted_weight = normalize_text(wanted.get("font_weight"))
            weight_ok = not wanted_weight or wanted_weight == normalize_text(candidate.get("fontWeight"))
            score = (0.75 if size_ok else 0.0) + (0.25 if weight_ok else 0.0)
            ranked.append((score + similarity * 0.001, index))
        if ranked:
            score, index = max(ranked)
            total += min(1.0, score)
            remaining.pop(index)
    return total / len(expected)


def recognized_names(analysis: dict[str, Any]) -> list[str]:
    names: list[str] = []
    for component in analysis.get("components") or []:
        if isinstance(component, dict):
            names.extend(str(component.get(key) or "") for key in ("name", "type"))
    tokens = analysis.get("tokens") or {}
    for group in ("colors", "typography"):
        for token in tokens.get(group) or []:
            if isinstance(token, dict):
                names.extend(str(token.get(key) or "") for key in ("name", "role"))
    return [value for value in names if value]


def score_names(expected: list[Any], predicted: list[str]) -> float:
    if not expected:
        return 1.0
    remaining = list(predicted)
    matched = 0
    for item in expected:
        wanted = item.get("name") if isinstance(item, dict) else item
        similarities = [(text_similarity(wanted, candidate), index) for index, candidate in enumerate(remaining)]
        similarities = [entry for entry in similarities if entry[0] >= 0.75]
        if similarities:
            _, index = max(similarities)
            remaining.pop(index)
            matched += 1
    return matched / len(expected)


def score_fixture(manifest: dict[str, Any], analysis: dict[str, Any]) -> dict[str, Any]:
    validate_manifest(manifest, manifest.get("id", "manifest"))
    validate_analysis(analysis, manifest["id"])
    expected = manifest["expected"]
    elements = expected["required_elements"]
    matches, missing = match_elements(
        elements,
        analysis["elements"],
        float(manifest["canvas"]["width"]),
        float(manifest["canvas"]["height"]),
    )
    recall = len(matches) / len(elements) if elements else 1.0
    bbox_score = sum(iou_credit(match["iou"]) for match in matches) / len(elements) if elements else 1.0
    color_score = score_colors(expected["colors"], predicted_colors(analysis))
    typography_score = score_typography(expected["typography"], predicted_typography(analysis))
    component_score = score_names(expected["components"], recognized_names(analysis))
    dimensions = {
        "required_element_recall": recall,
        "bounding_box_iou": bbox_score,
        "color_matching": color_score,
        "typography_matching": typography_score,
        "component_token_recognition": component_score,
    }
    score = sum(dimensions[name] * weight for name, weight in WEIGHTS.items())
    hard_labels = {
        item["label"] or item["type"] for item in elements if item["hard_required"]
    }
    missing_hard = sorted(hard_labels.intersection(missing))
    minimum = float(manifest.get("minimum_score", DEFAULT_FIXTURE_MINIMUM))
    passed = not missing_hard and score >= minimum
    return {
        "id": manifest["id"],
        "passed": passed,
        "score": round(score, 6),
        "minimum_score": minimum,
        "dimensions": {key: round(value, 6) for key, value in dimensions.items()},
        "missing_required": sorted(missing),
        "missing_hard_required": missing_hard,
        "matches": [
            {
                "label": match["label"],
                "type": match["type"],
                "iou": round(match["iou"], 6),
                "coordinate_mae_px": round(match["coordinate_mae_px"], 6),
                "text_similarity": round(match["text_similarity"], 6),
            }
            for match in matches
        ],
    }


def discover_manifests(corpus: Path) -> list[Path]:
    if not corpus.is_dir():
        raise EvaluationError("corpus directory does not exist")
    paths = sorted(corpus.glob("*/manifest.json"))
    if not paths:
        raise EvaluationError("corpus contains no */manifest.json fixtures")
    return paths


def load_json(path: Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EvaluationError(f"{label} is not valid readable JSON") from exc


def resolve_corpus(value: str, repo_root: Path) -> Path:
    if value == "public":
        return repo_root / "evals" / "design-quality" / "public"
    return Path(value).expanduser().resolve()


def resolve_skill_dir(value: str | None) -> Path:
    if value:
        return Path(value).expanduser().resolve()
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
    return (codex_home / "skills" / "gemini-design-agent").resolve()


def run_wrapper(skill_dir: Path, args: Iterable[str], timeout_seconds: int) -> dict[str, Any]:
    wrapper = skill_dir / "gda_skill.py"
    if not wrapper.is_file():
        raise EvaluationError("installed skill wrapper is missing")
    environment = os.environ.copy()
    environment["GDA_DISABLE_AUTH_ONBOARDING"] = "1"
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
    try:
        payload = json.loads(process.stdout)
    except json.JSONDecodeError as exc:
        raise EvaluationError("installed skill returned invalid JSON") from exc
    if process.returncode != 0 or payload.get("ok") is not True:
        error = payload.get("error") if isinstance(payload, dict) else None
        code = error.get("code") if isinstance(error, dict) else "LIVE_ANALYSIS_FAILED"
        raise EvaluationError(f"installed skill failed with {code}")
    return payload


def live_analysis(
    skill_dir: Path,
    fixture_dir: Path,
    manifest: dict[str, Any],
    timeout_seconds: int,
) -> dict[str, Any]:
    image = (fixture_dir / manifest["image"]).resolve()
    if not image.is_file():
        raise EvaluationError(f"{manifest['id']}: fixture image is missing")
    with tempfile.TemporaryDirectory(prefix="gda-quality-") as temporary:
        project_dir = Path(temporary) / "project.gda"
        run_wrapper(
            skill_dir,
            ["setup", "--project-dir", str(project_dir), "--project-name", f"Quality {manifest['id']}"],
            timeout_seconds,
        )
        payload = run_wrapper(
            skill_dir,
            [
                "analyze",
                "--image", str(image),
                "--screen", manifest["screen"],
                "--request", manifest["request"],
                "--project-dir", str(project_dir),
                "--theme", str(manifest.get("theme", "unspecified")),
                "--locale-direction", str(manifest.get("locale_direction", "ltr")),
                "--timeout-seconds", str(timeout_seconds),
            ],
            timeout_seconds + 30,
        )
    return unwrap_analysis(payload, manifest["id"])


def evaluate_corpus(
    corpus: Path,
    mode: str,
    skill_dir: Path | None = None,
    timeout_seconds: int = 180,
    corpus_minimum: float = DEFAULT_CORPUS_MINIMUM,
) -> dict[str, Any]:
    results: list[dict[str, Any]] = []
    for manifest_path in discover_manifests(corpus):
        manifest = validate_manifest(load_json(manifest_path, "manifest"), manifest_path.parent.name)
        fixture_dir = manifest_path.parent
        validate_fixture_files(fixture_dir, manifest)
        if mode == "recorded":
            recorded_name = manifest.get("recorded_analysis", "recorded-analysis.json")
            analysis = unwrap_analysis(load_json(fixture_dir / recorded_name, manifest["id"]), manifest["id"])
        elif mode == "live":
            if skill_dir is None:
                raise EvaluationError("live mode requires an installed skill directory")
            analysis = live_analysis(skill_dir, fixture_dir, manifest, timeout_seconds)
        else:
            raise EvaluationError(f"unsupported mode: {mode}")
        results.append(score_fixture(manifest, analysis))

    mean = sum(result["score"] for result in results) / len(results)
    passed = all(result["passed"] for result in results) and mean >= corpus_minimum
    return {
        "schema_version": "1.0",
        "mode": mode,
        "passed": passed,
        "fixture_count": len(results),
        "mean_score": round(mean, 6),
        "minimum_mean_score": corpus_minimum,
        "fixtures": results,
    }


def _signal_present(signal: dict[str, Any], analysis: dict[str, Any]) -> bool:
    kind = signal.get("kind")
    value = signal.get("value")
    if not isinstance(value, str) or not value:
        return False
    if kind == "component":
        return any(text_similarity(value, candidate) >= 0.75 for candidate in recognized_names(analysis))
    if kind == "color":
        return any(color_distance(value, candidate) == 0 for candidate in predicted_colors(analysis))
    return False


def _analysis_safety_counts(analysis: dict[str, Any]) -> tuple[int, int]:
    elements = [item for item in analysis.get("elements", []) if isinstance(item, dict)]
    ids = {item.get("id") for item in elements if isinstance(item.get("id"), str)}
    unresolved = 0
    invalid = 0
    for element in elements:
        box = element.get("bbox1000")
        if not isinstance(box, dict):
            invalid += 1
        else:
            values = [box.get(key) for key in ("xmin", "ymin", "xmax", "ymax")]
            if (
                any(not isinstance(value, (int, float)) or isinstance(value, bool) for value in values)
                or not (0 <= values[0] < values[2] <= 1000)
                or not (0 <= values[1] < values[3] <= 1000)
            ):
                invalid += 1
        unresolved += sum(child not in ids or child == element.get("id") for child in element.get("children", []))
        typography = element.get("typography")
        if isinstance(typography, dict):
            for key, minimum, maximum in (("fontSizePx", 1, 512), ("lineHeightPx", 1, 1024), ("letterSpacingPx", -64, 64)):
                value = typography.get(key)
                if value is not None and (not isinstance(value, (int, float)) or not minimum <= value <= maximum):
                    invalid += 1
        spacing = element.get("spacing")
        if isinstance(spacing, dict):
            for key in ("top", "right", "bottom", "left", "vertical", "horizontal"):
                value = spacing.get(key)
                if value is not None and (not isinstance(value, (int, float)) or not 0 <= value <= 4096):
                    invalid += 1
        radius = element.get("borderRadiusPx")
        if radius is not None and (not isinstance(radius, (int, float)) or not 0 <= radius <= 4096):
            invalid += 1
    for component in analysis.get("components", []):
        if isinstance(component, dict):
            unresolved += sum(element_id not in ids for element_id in component.get("elementIds", []))
    tokens = analysis.get("tokens", {})
    if isinstance(tokens, dict):
        invalid += sum(not isinstance(value, (int, float)) or not 0 <= value <= 4096 for value in tokens.get("spacingScalePx", []))
        invalid += sum(not isinstance(value, (int, float)) or not 0 <= value <= 4096 for value in tokens.get("radiiPx", []))
    return unresolved, invalid


def _scale_mae(expected: list[Any], predicted: list[Any]) -> list[float]:
    numeric = [float(value) for value in predicted if isinstance(value, (int, float)) and not isinstance(value, bool)]
    return [min((abs(float(value) - candidate) for candidate in numeric), default=math.inf) for value in expected]


def evaluate_sequential_corpus(
    corpus: Path,
    mode: str,
    skill_dir: Path | None = None,
    timeout_seconds: int = 180,
) -> dict[str, Any]:
    """Evaluate an ordered screen sequence and report memory-safety invariants.

    Recorded mode is deterministic. Live mode intentionally uses one temporary
    project for the whole sequence so later screens can recall earlier ones.
    """
    manifests = [
        (path, validate_manifest(load_json(path, "manifest"), path.parent.name))
        for path in discover_manifests(corpus)
    ]
    manifests.sort(key=lambda item: (int(item[1].get("sequence", 0)), item[1]["id"]))
    results: list[dict[str, Any]] = []
    unsafe_global_memories = 0
    unresolved_references = 0
    invalid_measurements = 0
    prompt_sizes: list[int] = []
    recall_signal_count = 0
    recalled_signal_count = 0
    component_signal_count = 0
    recalled_component_count = 0
    coordinate_errors: list[float] = []
    exact_color_expected = 0
    exact_color_matched = 0
    spacing_errors: list[float] = []
    radius_errors: list[float] = []
    global_memory: dict[tuple[str, str], str] = {}
    contradictory_global_memories = 0

    temporary = tempfile.TemporaryDirectory(prefix="gda-sequential-quality-") if mode == "live" else None
    try:
        project_dir = Path(temporary.name) / "project.gda" if temporary else None
        if project_dir is not None:
            if skill_dir is None:
                raise EvaluationError("sequential live mode requires an installed skill directory")
            run_wrapper(skill_dir, ["setup", "--project-dir", str(project_dir), "--project-name", "Sequential Quality"], timeout_seconds)
        for manifest_path, manifest in manifests:
            fixture_dir = manifest_path.parent
            validate_fixture_files(fixture_dir, manifest)
            if mode == "recorded":
                analysis = unwrap_analysis(load_json(fixture_dir / manifest.get("recorded_analysis", "recorded-analysis.json"), manifest["id"]), manifest["id"])
            elif mode == "live" and project_dir is not None and skill_dir is not None:
                image = (fixture_dir / manifest["image"]).resolve()
                payload = run_wrapper(skill_dir, ["analyze", "--image", str(image), "--screen", manifest["screen"], "--request", manifest["request"], "--project-dir", str(project_dir), "--timeout-seconds", str(timeout_seconds)], timeout_seconds + 30)
                analysis = unwrap_analysis(payload, manifest["id"])
            else:
                raise EvaluationError(f"unsupported sequential mode: {mode}")
            result = score_fixture(manifest, analysis)
            results.append(result)
            coordinate_errors.extend(match["coordinate_mae_px"] for match in result["matches"])
            expected_colors = [item.get("hex") for item in manifest["expected"].get("colors", []) if isinstance(item, dict)]
            actual_colors = {value.upper() for value in predicted_colors(analysis)}
            exact_color_expected += len(expected_colors)
            exact_color_matched += sum(isinstance(value, str) and value.upper() in actual_colors for value in expected_colors)
            tokens = analysis.get("tokens", {}) if isinstance(analysis.get("tokens"), dict) else {}
            spacing_errors.extend(_scale_mae(manifest["expected"].get("spacing_scale_px", []), tokens.get("spacingScalePx", [])))
            radius_errors.extend(_scale_mae(manifest["expected"].get("radii_px", []), tokens.get("radiiPx", [])))
            unresolved, invalid = _analysis_safety_counts(analysis)
            unresolved_references += unresolved
            invalid_measurements += invalid
            for signal in manifest.get("recall_signals", []):
                if not isinstance(signal, dict):
                    continue
                recall_signal_count += 1
                present = _signal_present(signal, analysis)
                recalled_signal_count += int(present)
                if signal.get("kind") == "component":
                    component_signal_count += 1
                    recalled_component_count += int(present)
            for write in analysis.get("memoryWrites", []):
                if not isinstance(write, dict) or write.get("scope") != "global":
                    continue
                if write.get("type") in {"implementation_instruction", "user_preference", "screen_fact", "warning"}:
                    unsafe_global_memories += 1
                key = (normalize_text(write.get("type")), normalize_text(write.get("componentName")))
                content = normalize_text(write.get("content"))
                if key in global_memory and global_memory[key] != content:
                    contradictory_global_memories += 1
                global_memory[key] = content
            prompt_sizes.append(len(manifest["request"]) + len(manifest.get("screen", "")))
    finally:
        if temporary is not None:
            temporary.cleanup()

    schema_success_rate = len(results) / len(manifests) if manifests else 0.0
    memory_recall_coverage = recalled_signal_count / recall_signal_count if recall_signal_count else 1.0
    component_name_reuse = recalled_component_count / component_signal_count if component_signal_count else 1.0
    coordinate_mae = sum(coordinate_errors) / len(coordinate_errors) if coordinate_errors else 0.0
    exact_color_rate = exact_color_matched / exact_color_expected if exact_color_expected else 1.0
    spacing_mae = sum(spacing_errors) / len(spacing_errors) if spacing_errors else 0.0
    radius_mae = sum(radius_errors) / len(radius_errors) if radius_errors else 0.0
    prompt_growth = max(prompt_sizes, default=0) - min(prompt_sizes, default=0)
    passed = (
        all(result["passed"] for result in results)
        and schema_success_rate == 1.0
        and memory_recall_coverage == 1.0
        and exact_color_rate == 1.0
        and math.isfinite(spacing_mae)
        and math.isfinite(radius_mae)
        and unsafe_global_memories == 0
        and contradictory_global_memories == 0
        and unresolved_references == 0
        and invalid_measurements == 0
        and max(prompt_sizes, default=0) <= 7_500
    )
    return {
        "schema_version": "1.0",
        "mode": mode,
        "fixture_count": len(results),
        "fixtures": results,
        "metrics": {
            "schema_success_rate": schema_success_rate,
            "major_element_coordinate_mae_px": round(coordinate_mae, 6),
            "color_token_exact_match_rate": round(exact_color_rate, 6),
            "spacing_token_mae_px": round(spacing_mae, 6),
            "radius_token_mae_px": round(radius_mae, 6),
            "component_name_reuse": round(component_name_reuse, 6),
            "design_token_consistency": round(memory_recall_coverage, 6),
            "memory_recall_coverage": round(memory_recall_coverage, 6),
            "unsafe_global_memory_count": unsafe_global_memories,
            "contradictory_global_memory_count": contradictory_global_memories,
            "unresolved_element_reference_count": unresolved_references,
            "invalid_final_measurement_count": invalid_measurements,
            "max_prompt_context_characters": max(prompt_sizes, default=0),
            "prompt_context_growth_characters": prompt_growth,
        },
        "passed": passed,
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Score GeminiDesignAgent design-analysis quality.")
    parser.add_argument("--mode", choices=("recorded", "live"), required=True)
    parser.add_argument("--corpus", default="public", help="'public' or a corpus directory")
    parser.add_argument("--skill-dir", default=None, help="Installed skill directory for live mode")
    parser.add_argument("--timeout-seconds", type=int, default=180)
    parser.add_argument("--minimum-mean-score", type=float, default=DEFAULT_CORPUS_MINIMUM)
    parser.add_argument("--sequential", action="store_true", help="Evaluate fixtures as an ordered memory sequence.")
    parser.add_argument("--output", default=None, help="Optional redacted JSON report path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    repo_root = Path(__file__).resolve().parents[1]
    try:
        report = (evaluate_sequential_corpus(
            resolve_corpus(args.corpus, repo_root), args.mode,
            resolve_skill_dir(args.skill_dir) if args.mode == "live" else None,
            args.timeout_seconds,
        ) if args.sequential else evaluate_corpus(
            resolve_corpus(args.corpus, repo_root),
            args.mode,
            resolve_skill_dir(args.skill_dir) if args.mode == "live" else None,
            args.timeout_seconds,
            args.minimum_mean_score,
        ))
    except (EvaluationError, subprocess.TimeoutExpired) as exc:
        report = {
            "schema_version": "1.0",
            "mode": args.mode,
            "passed": False,
            "error": {"code": "QUALITY_EVALUATION_FAILED", "message": str(exc)},
        }
    output = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if args.output:
        destination = Path(args.output).expanduser()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0 if report.get("passed") is True else 1


if __name__ == "__main__":
    raise SystemExit(main())
