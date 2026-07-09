#!/usr/bin/env python3
"""Validate the Codex skill metadata and its complete Python runtime closure."""

from __future__ import annotations

import argparse
import ast
import json
import sys
from dataclasses import dataclass
from pathlib import Path


EXPECTED_SKILL_NAME = "gemini-design-agent"
EXPECTED_RUNTIME_FILES = frozenset({
    "gda_skill.py",
    "gda_auth.py",
    "gda_cli.py",
    "gda_commands.py",
    "gda_constants.py",
    "gda_envelope.py",
    "gda_handoff.py",
    "gda_runner.py",
})
REQUIRED_RUNTIME_FILES = EXPECTED_RUNTIME_FILES
REQUIRED_SECTIONS = {
    "# Gemini Design Agent Skill",
    "## Tool",
    "## Authentication",
    "## Analyze screenshot",
}


@dataclass(frozen=True)
class ValidationIssue:
    code: str
    message: str
    path: str

    def as_dict(self) -> dict[str, str]:
        return {"code": self.code, "message": self.message, "path": self.path}


def runtime_files(skill_dir: Path) -> list[Path]:
    return [skill_dir / filename for filename in sorted(EXPECTED_RUNTIME_FILES)]


def _declared_runtime_files(constants_file: Path) -> set[str] | None:
    try:
        tree = ast.parse(constants_file.read_text(encoding="utf-8"), filename=str(constants_file))
    except (OSError, SyntaxError):
        return None
    for node in tree.body:
        if isinstance(node, ast.Assign):
            if any(isinstance(target, ast.Name) and target.id == "RUNTIME_PYTHON_FILES" for target in node.targets):
                try:
                    value = ast.literal_eval(node.value)
                except (ValueError, TypeError, SyntaxError):
                    return None
                if isinstance(value, (tuple, list)) and all(isinstance(item, str) for item in value):
                    return set(value)
    return None


def _parse_frontmatter(skill_file: Path) -> tuple[dict[str, str], list[ValidationIssue]]:
    issues: list[ValidationIssue] = []
    try:
        raw = skill_file.read_text(encoding="utf-8")
    except OSError as exc:
        return {}, [ValidationIssue("SKILL_FILE_UNREADABLE", str(exc), str(skill_file))]

    lines = raw.splitlines()
    if not lines or lines[0] != "---":
        return {}, [ValidationIssue(
            "SKILL_FRONTMATTER_MISSING",
            "SKILL.md must begin with a YAML frontmatter delimiter as its first bytes.",
            str(skill_file),
        )]

    try:
        closing = lines.index("---", 1)
    except ValueError:
        return {}, [ValidationIssue(
            "SKILL_FRONTMATTER_UNTERMINATED",
            "SKILL.md frontmatter is missing its closing delimiter.",
            str(skill_file),
        )]

    metadata: dict[str, str] = {}
    for line_number, line in enumerate(lines[1:closing], start=2):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            issues.append(ValidationIssue(
                "SKILL_FRONTMATTER_INVALID",
                f"Frontmatter line {line_number} is not a key-value pair.",
                str(skill_file),
            ))
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if not key or key in metadata:
            issues.append(ValidationIssue(
                "SKILL_FRONTMATTER_INVALID",
                f"Frontmatter line {line_number} has an empty or duplicate key.",
                str(skill_file),
            ))
            continue
        metadata[key] = value

    body = "\n".join(lines[closing + 1:])
    for section in sorted(REQUIRED_SECTIONS):
        if section not in body:
            issues.append(ValidationIssue(
                "SKILL_SECTION_MISSING",
                f"Required documentation section is missing: {section}",
                str(skill_file),
            ))
    return metadata, issues


def _local_imports(path: Path) -> set[str]:
    source = path.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(path))
    imports: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imports.update(alias.name.split(".", 1)[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imports.add(node.module.split(".", 1)[0])
    return {module for module in imports if module.startswith("gda_")}


def validate_skill_dir(skill_dir: Path) -> list[ValidationIssue]:
    skill_dir = skill_dir.expanduser().resolve()
    issues: list[ValidationIssue] = []
    skill_file = skill_dir / "SKILL.md"
    metadata, metadata_issues = _parse_frontmatter(skill_file)
    issues.extend(metadata_issues)

    if metadata and metadata.get("name") != EXPECTED_SKILL_NAME:
        issues.append(ValidationIssue(
            "SKILL_NAME_INVALID",
            f"Skill name must be exactly {EXPECTED_SKILL_NAME!r}.",
            str(skill_file),
        ))
    if metadata and not metadata.get("description", "").strip():
        issues.append(ValidationIssue(
            "SKILL_DESCRIPTION_MISSING",
            "Skill description must be present and non-empty.",
            str(skill_file),
        ))

    discovered = {path.name for path in skill_dir.glob("gda_*.py") if path.is_file()}
    for missing in sorted(EXPECTED_RUNTIME_FILES - discovered):
        issues.append(ValidationIssue(
            "SKILL_RUNTIME_FILE_MISSING",
            f"Required runtime file is missing: {missing}",
            str(skill_dir / missing),
        ))

    for unexpected in sorted(discovered - EXPECTED_RUNTIME_FILES):
        issues.append(ValidationIssue(
            "SKILL_RUNTIME_FILE_UNEXPECTED",
            f"Unexpected runtime-shaped file is not allowed: {unexpected}",
            str(skill_dir / unexpected),
        ))

    declared = _declared_runtime_files(skill_dir / "gda_constants.py")
    if declared != EXPECTED_RUNTIME_FILES:
        issues.append(ValidationIssue(
            "SKILL_RUNTIME_CONTRACT_MISMATCH",
            "gda_constants.RUNTIME_PYTHON_FILES must match the exact installer runtime contract.",
            str(skill_dir / "gda_constants.py"),
        ))

    for path in runtime_files(skill_dir):
        if not path.is_file():
            continue
        try:
            source = path.read_text(encoding="utf-8")
            compile(source, str(path), "exec")
            local_imports = _local_imports(path)
        except (OSError, SyntaxError) as exc:
            issues.append(ValidationIssue(
                "SKILL_PYTHON_INVALID",
                f"Python runtime file does not compile: {exc}",
                str(path),
            ))
            continue
        for module in sorted(local_imports):
            imported_path = skill_dir / f"{module}.py"
            if not imported_path.is_file():
                issues.append(ValidationIssue(
                    "SKILL_LOCAL_IMPORT_MISSING",
                    f"{path.name} imports missing local module {module}.py.",
                    str(imported_path),
                ))
    return issues


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skill-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "skills" / EXPECTED_SKILL_NAME,
    )
    parser.add_argument("--json", action="store_true", dest="as_json")
    return parser


def main() -> int:
    args = _parser().parse_args()
    issues = validate_skill_dir(args.skill_dir)
    payload = {
        "ok": not issues,
        "skill_dir": str(args.skill_dir.expanduser().resolve()),
        "runtime_files": [path.name for path in runtime_files(args.skill_dir)],
        "issues": [issue.as_dict() for issue in issues],
    }
    if args.as_json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
    elif issues:
        for issue in issues:
            print(f"{issue.code}: {issue.message} ({issue.path})", file=sys.stderr)
    else:
        print(f"Validated {EXPECTED_SKILL_NAME} ({len(payload['runtime_files'])} Python runtime files).")
    return 0 if not issues else 1


if __name__ == "__main__":
    raise SystemExit(main())
