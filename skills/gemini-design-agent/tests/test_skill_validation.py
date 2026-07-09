import shutil
import tempfile
import unittest
from pathlib import Path

import sys

SKILL_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = SKILL_DIR.parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from validate_skill import REQUIRED_RUNTIME_FILES, validate_skill_dir


def create_minimal_skill(path: Path) -> None:
    path.mkdir(parents=True)
    (path / "SKILL.md").write_text(
        "---\n"
        "name: gemini-design-agent\n"
        "description: Test skill\n"
        "---\n\n"
        "# Gemini Design Agent Skill\n\n"
        "## Tool\n\nTest.\n\n"
        "## Authentication\n\nTest.\n\n"
        "## Analyze screenshot\n\nTest.\n",
        encoding="utf-8",
    )
    for filename in REQUIRED_RUNTIME_FILES:
        (path / filename).write_text("from __future__ import annotations\n", encoding="utf-8")
    (path / "gda_constants.py").write_text(
        "RUNTIME_PYTHON_FILES = " + repr(tuple(sorted(REQUIRED_RUNTIME_FILES))) + "\n",
        encoding="utf-8",
    )


class SkillValidationTests(unittest.TestCase):
    def test_repository_skill_is_valid(self):
        self.assertEqual(validate_skill_dir(SKILL_DIR), [])

    def test_missing_frontmatter_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "skill"
            create_minimal_skill(skill)
            (skill / "SKILL.md").write_text("# Gemini Design Agent Skill\n", encoding="utf-8")

            issues = validate_skill_dir(skill)

            self.assertIn("SKILL_FRONTMATTER_MISSING", {issue.code for issue in issues})

    def test_wrong_name_and_empty_description_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "skill"
            create_minimal_skill(skill)
            text = (skill / "SKILL.md").read_text(encoding="utf-8")
            text = text.replace("name: gemini-design-agent", "name: wrong")
            text = text.replace("description: Test skill", "description:")
            (skill / "SKILL.md").write_text(text, encoding="utf-8")

            codes = {issue.code for issue in validate_skill_dir(skill)}

            self.assertIn("SKILL_NAME_INVALID", codes)
            self.assertIn("SKILL_DESCRIPTION_MISSING", codes)

    def test_missing_transitive_local_import_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "skill"
            create_minimal_skill(skill)
            (skill / "gda_skill.py").write_text("import gda_missing\n", encoding="utf-8")

            issues = validate_skill_dir(skill)

            self.assertIn("SKILL_LOCAL_IMPORT_MISSING", {issue.code for issue in issues})

    def test_unexpected_runtime_shaped_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "skill"
            create_minimal_skill(skill)
            (skill / "gda_extra.py").write_text("DEBUG = True\n", encoding="utf-8")

            issues = validate_skill_dir(skill)

            self.assertIn("SKILL_RUNTIME_FILE_UNEXPECTED", {issue.code for issue in issues})

    def test_python_syntax_error_is_rejected_without_writing_pycache(self):
        with tempfile.TemporaryDirectory() as tmp:
            skill = Path(tmp) / "skill"
            create_minimal_skill(skill)
            (skill / "gda_runner.py").write_text("def broken(:\n", encoding="utf-8")

            issues = validate_skill_dir(skill)

            self.assertIn("SKILL_PYTHON_INVALID", {issue.code for issue in issues})
            self.assertFalse((skill / "__pycache__").exists())


if __name__ == "__main__":
    unittest.main()
