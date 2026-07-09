#!/usr/bin/env python3
"""Fail closed when tracked files or Git history contain release-private data."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


SECRET_PATTERNS = {
    "google_api_key": re.compile(rb"AIza[0-9A-Za-z_-]{30,}"),
    "literal_gemini_assignment": re.compile(
        rb"GEMINI_API_KEY\s*=\s*['\"](?!\$|\.\.\.|<)[^'\"\r\n]{8,}['\"]"
    ),
}

PRIVATE_SUFFIXES = {".db", ".sqlite", ".sqlite3", ".jsonl"}
PRIVATE_PREFIXES = ("evals/design-quality/private/",)


def is_private_data_path(path: Path, path_string: str) -> bool:
    has_gda_directory = any(part == ".gda" or part.endswith(".gda") for part in path.parts)
    return (
        has_gda_directory
        or path_string.startswith(PRIVATE_PREFIXES)
        or path.suffix.lower() in PRIVATE_SUFFIXES
    )


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args], stderr=subprocess.STDOUT)


def main() -> int:
    failures: list[str] = []
    tracked = git("ls-files", "-z").split(b"\0")
    for raw_path in tracked:
        if not raw_path:
            continue
        path_string = raw_path.decode("utf-8", errors="replace")
        path = Path(path_string)
        if is_private_data_path(path, path_string):
            failures.append(f"tracked private-data path: {path_string}")
            continue
        try:
            data = path.read_bytes()
        except OSError as error:
            failures.append(f"cannot inspect tracked file {path_string}: {error}")
            continue
        for name, pattern in SECRET_PATTERNS.items():
            if pattern.search(data):
                failures.append(f"potential {name} in tracked file: {path_string}")

    history = git("log", "-p", "--all", "--no-ext-diff", "--binary")
    for name, pattern in SECRET_PATTERNS.items():
        if pattern.search(history):
            failures.append(f"potential {name} in Git history")

    if failures:
        print("public release audit failed", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("public release audit passed: no tracked private-data paths or key-shaped values found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
